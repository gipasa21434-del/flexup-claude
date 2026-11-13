import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Keeps at most `capacity` AVQueuePlayers alive (current + neighbours for preloading).
/// Only the active one plays; everything else is paused and evicted LRU-style to save memory/battery.
@MainActor
final class PlayerPool: ObservableObject {
    enum State: Equatable { case loading, ready, failed(String) }

    final class Entry {
        let id: UUID
        let player: AVQueuePlayer
        var looper: AVPlayerLooper?
        var statusObservation: NSKeyValueObservation?
        var endObserver: AnyCancellable?
        init(id: UUID, player: AVQueuePlayer) { self.id = id; self.player = player }
    }

    @Published private(set) var states: [UUID: State] = [:]
    @Published private(set) var activeID: UUID?
    @Published var isMuted: Bool { didSet { applyMute() } }
    /// User paused the active video with a tap.
    @Published private(set) var isUserPaused = false
    let progress = PlaybackProgress()

    var capacity = 3
    var loops = true
    var preferredBuffer: TimeInterval = 4
    private var entries: [UUID: Entry] = [:]
    private var lru: [UUID] = []
    private var timeObserver: (player: AVPlayer, token: Any)?
    private var suspended = false
    private var resumeAfterSuspend = false
    private var bag = Set<AnyCancellable>()
    var onPlayedToEnd: ((UUID) -> Void)?

    init(startMuted: Bool) {
        isMuted = startMuted
        configureAudioSession()
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                // Headphones unplugged → pause instead of blasting the speaker.
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self?.pauseByUser()
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self?.pauseByUser()
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.trim(keep: self?.activeID.map { [$0] } ?? []) }
            .store(in: &bag)
    }

    // MARK: Audio session

    /// Muted: `.ambient` (respects the silent switch, mixes with other apps' audio).
    /// Unmuted by explicit user action: `.playback`.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(isMuted ? .ambient : .playback, mode: .moviePlayback,
                                 options: isMuted ? [.mixWithOthers] : [])
        try? session.setActive(true, options: [])
    }

    private func applyMute() {
        configureAudioSession()
        entries.values.forEach { $0.player.isMuted = isMuted }
    }

    // MARK: Players

    /// Read-only lookup for views (never creates players during a SwiftUI update).
    func existingPlayer(for id: UUID) -> AVPlayer? { entries[id]?.player }

    func player(for id: UUID, url: URL) -> AVQueuePlayer {
        if let e = entries[id] { touch(id); return e.player }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = preferredBuffer
        let player = AVQueuePlayer()
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        let entry = Entry(id: id, player: player)
        if loops {
            entry.looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        states[id] = .loading
        entry.statusObservation = player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.currentItem?.status
            let message = p.currentItem?.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay: self.states[id] = .ready
                case .failed: self.states[id] = .failed(message ?? "Видео недоступно")
                default: break
                }
            }
        }
        entry.endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .compactMap { $0.object as? AVPlayerItem }
            .filter { [weak player] item in player?.currentItem === item }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onPlayedToEnd?(id) }
        entries[id] = entry
        touch(id)
        trim(keep: [])
        return player
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func trim(keep: [UUID]) {
        while entries.count > capacity, let victim = lru.first(where: { $0 != activeID && !keep.contains($0) }) {
            release(victim)
        }
    }

    func release(_ id: UUID) {
        guard let e = entries.removeValue(forKey: id) else { return }
        e.player.pause()
        e.looper?.disableLooping()
        e.statusObservation?.invalidate()
        e.endObserver?.cancel()
        e.player.removeAllItems()
        lru.removeAll { $0 == id }
        states[id] = nil
        if timeObserver?.player === e.player { removeTimeObserver() }
    }

    func releaseAll() {
        entries.keys.forEach(release)
        activeID = nil
    }

    /// Makes `id` the only playing video and warms up the neighbours.
    /// `autoplay == false` leaves it paused until the user taps.
    func activate(id: UUID, url: URL, neighbours: [(UUID, URL)], autoplay: Bool = true) {
        if activeID != id { isUserPaused = !autoplay }
        activeID = id
        let active = player(for: id, url: url)
        for (nid, nurl) in neighbours { _ = player(for: nid, url: nurl) }
        let keep = [id] + neighbours.map(\.0)
        for (eid, e) in entries where eid != id { e.player.pause(); if !keep.contains(eid) { e.player.seek(to: .zero) } }
        trim(keep: keep)
        installTimeObserver(on: active)
        if isUserPaused { active.pause(); return }
        if suspended { resumeAfterSuspend = true } else { active.play() }
    }

    /// Pauses the current video without marking it as user-paused (screen pushed on top, tab switch).
    func pauseActive() {
        guard let id = activeID else { return }
        entries[id]?.player.pause()
    }

    func deactivate(id: UUID) {
        guard activeID == id else { return }
        entries[id]?.player.pause()
    }

    func togglePause() {
        guard let id = activeID, let p = entries[id]?.player else { return }
        if p.timeControlStatus == .paused { isUserPaused = false; if !suspended { p.play() } }
        else { isUserPaused = true; p.pause() }
    }

    func pauseByUser() {
        guard let id = activeID else { return }
        entries[id]?.player.pause()
        isUserPaused = true
    }

    /// App went to background or a full-screen flow (creation) covers everything.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        if let id = activeID, let p = entries[id]?.player { resumeAfterSuspend = p.timeControlStatus != .paused }
        entries.values.forEach { $0.player.pause() }
    }

    /// Undo `suspend()`: plays again only what was playing before.
    func resume() {
        guard suspended else { return }
        suspended = false
        if resumeAfterSuspend, !isUserPaused, let id = activeID { entries[id]?.player.play() }
        resumeAfterSuspend = false
    }

    func seek(to fraction: Double) {
        guard let id = activeID, let p = entries[id]?.player, let d = p.currentItem?.duration, d.isNumeric else { return }
        p.seek(to: CMTime(seconds: d.seconds * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func retry(id: UUID, url: URL) {
        release(id)
        _ = player(for: id, url: url)
        if activeID == id { activate(id: id, url: url, neighbours: []) }
    }

    private func installTimeObserver(on player: AVPlayer) {
        if timeObserver?.player === player { return }
        removeTimeObserver()
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self, weak player] time in
            guard let d = player?.currentItem?.duration, d.isNumeric, d.seconds > 0 else { return }
            let value = time.seconds.truncatingRemainder(dividingBy: d.seconds) / d.seconds
            Task { @MainActor in self?.progress.value = value }
        }
        timeObserver = (player, token)
    }

    private func removeTimeObserver() {
        if let t = timeObserver { t.player.removeTimeObserver(t.token) }
        timeObserver = nil
        progress.value = 0
    }

    var liveEntriesCount: Int { entries.count }
}

/// Separate tiny object so only the progress bar re-renders 10×/s, not the whole feed.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var value: Double = 0
}

/// AVPlayerLayer host for SwiftUI.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = .black
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }

    static func dismantleUIView(_ v: PlayerUIView, coordinator: ()) {
        v.playerLayer.player = nil
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

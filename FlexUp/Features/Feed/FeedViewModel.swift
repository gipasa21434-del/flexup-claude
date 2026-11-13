import SwiftUI
import FlexCore

enum FeedPage: Hashable {
    case video(UUID)
    case end
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)
}

/// Drives any vertical video list: the main feed (For You / Following / MOOD FEED) or a fixed list
/// opened from a profile grid, hashtag or search result.
@MainActor
final class FeedViewModel: ObservableObject {
    enum Source { case main, fixed }

    @Published private(set) var items: [UUID: FeedItem] = [:]
    @Published private(set) var pages: [FeedPage] = []
    @Published var state: LoadState = .idle
    @Published var activeIndex = 0 { didSet { if oldValue != activeIndex { activeChanged(from: oldValue) } } }
    @Published var kind: FeedKind = .forYou
    @Published var mood: Mood?
    @Published var burstID: UUID?
    @Published var pendingIDs: Set<UUID> = []

    let source: Source
    weak var app: AppModel?
    private var activeSince = Date()
    private var watchedThisSession = Set<UUID>()
    private var loadTask: Task<Void, Never>?

    init(source: Source = .main, items fixed: [FeedItem] = [], startAt: UUID? = nil) {
        self.source = source
        if source == .fixed {
            setItems(fixed, appendEnd: false)
            activeIndex = fixed.firstIndex { $0.id == startAt } ?? 0
            state = .loaded
        }
    }

    var activeItem: FeedItem? {
        guard activeIndex < pages.count, case let .video(id) = pages[activeIndex] else { return nil }
        return items[id]
    }

    func item(_ id: UUID) -> FeedItem? { items[id] }

    private func setItems(_ list: [FeedItem], appendEnd: Bool) {
        var dict: [UUID: FeedItem] = [:]
        list.forEach { dict[$0.id] = $0 }
        items = dict
        pages = list.map { .video($0.id) } + (appendEnd && !list.isEmpty ? [.end] : [])
    }

    // MARK: Loading

    func load(force: Bool = false) async {
        guard source == .main, let app else { return }
        if state == .loading && !force { return }
        if items.isEmpty { state = .loading }
        let query = FeedQuery(kind: kind, mood: mood, hiddenTags: Set(app.settings.hiddenTags), interests: app.interests)
        do {
            let list = try await app.backend.feed(query)
            app.players.releaseAll()
            setItems(list, appendEnd: true)
            activeIndex = 0
            state = .loaded
            activate()
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) } else { app.show(error) }
        }
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { await load(force: true) }
    }

    func setKind(_ k: FeedKind) {
        guard k != kind else { return }
        if k == .following, app?.isGuest == true { app?.showAuthPrompt = true; return }
        kind = k
        items = [:]; pages = []
        reload()
    }

    func setMood(_ m: Mood?) {
        mood = m
        items = [:]; pages = []
        reload()
    }

    // MARK: Playback coordination

    func url(for item: FeedItem) -> URL? { MediaStore.url(for: item.video.source) }

    func activate() {
        guard let app else { return }
        guard let item = activeItem, let url = url(for: item) else { return }
        var neighbours: [(UUID, URL)] = []
        for offset in [1, -1] {
            let i = activeIndex + offset
            if i >= 0, i < pages.count, case let .video(id) = pages[i], let it = items[id], let u = self.url(for: it) {
                neighbours.append((id, u))
            }
        }
        app.players.onPlayedToEnd = { [weak self] id in self?.playedToEnd(id) }
        app.players.activate(id: item.id, url: url, neighbours: neighbours, autoplay: app.settings.autoplay)
        activeSince = Date()
        Task { await app.backend.recordView(videoID: item.id) }
    }

    private func activeChanged(from old: Int) {
        guard let app else { return }
        // A very quick skip is a weak "not for me" signal for recommendations.
        if old < pages.count, case let .video(id) = pages[old], let it = items[id],
           Date().timeIntervalSince(activeSince) < 1.2 {
            app.recordInterest(.skippedQuickly, video: it.video)
        }
        activate()
    }

    private func playedToEnd(_ id: UUID) {
        guard let app, let it = items[id], id == activeItem?.id else { return }
        if !watchedThisSession.contains(id) {
            watchedThisSession.insert(id)
            app.recordInterest(.watchedFully, video: it.video)
            app.record(.watched(it.video.mood))
        }
    }

    // MARK: Actions (optimistic UI + rollback on failure)

    private func update(_ id: UUID, _ change: (inout FeedItem) -> Void) {
        guard var it = items[id] else { return }
        change(&it)
        items[id] = it
    }

    func toggleLike(_ id: UUID, forceOn: Bool = false) {
        guard let app else { return }
        app.requireAccount {
            guard let before = items[id] else { return }
            let target = forceOn ? true : !before.isLiked
            if forceOn { burstID = id }
            guard target != before.isLiked else { return }
            Haptics.tap()
            update(id) { $0.isLiked = target; $0.video.likesCount += target ? 1 : -1 }
            if target { app.recordInterest(.like, video: before.video); app.record(.liked) }
            else { app.recordInterest(.unlike, video: before.video) }
            Task {
                do {
                    let v = try await app.backend.setLike(target, videoID: id)
                    update(id) { $0.video.likesCount = v.likesCount }
                } catch {
                    items[id] = before
                    app.show(error)
                }
            }
        }
    }

    func toggleSave(_ id: UUID) {
        guard let app else { return }
        app.requireAccount {
            guard let before = items[id] else { return }
            let target = !before.isSaved
            Haptics.tap()
            update(id) { $0.isSaved = target; $0.video.savesCount += target ? 1 : -1 }
            if target { app.recordInterest(.save, video: before.video); app.record(.interacted) }
            Task {
                do {
                    _ = try await app.backend.setSave(target, videoID: id)
                    app.show(target ? "Сохранено в избранное" : "Убрано из сохранённого", style: .success)
                } catch {
                    items[id] = before
                    app.show(error)
                }
            }
        }
    }

    func toggleFollow(_ id: UUID) {
        guard let app else { return }
        app.requireAccount {
            guard let before = items[id] else { return }
            let author = before.author.id
            let target = !before.isFollowingAuthor
            Haptics.medium()
            for key in items.keys where items[key]?.author.id == author { update(key) { $0.isFollowingAuthor = target } }
            Task {
                do {
                    _ = try await app.backend.setFollow(target, userID: author)
                    if target { app.record(.interacted) }
                } catch {
                    for key in items.keys where items[key]?.author.id == author { update(key) { $0.isFollowingAuthor = before.isFollowingAuthor } }
                    app.show(error)
                }
            }
        }
    }

    func didShare(_ id: UUID) {
        guard let app, let it = items[id] else { return }
        update(id) { $0.video.sharesCount += 1 }
        app.recordInterest(.share, video: it.video)
        Task { await app.backend.recordShare(videoID: id) }
    }

    func commentsChanged(_ id: UUID, delta: Int) {
        update(id) { $0.video.commentsCount = max(0, $0.video.commentsCount + delta) }
        if delta > 0 { app?.record(.interacted) }
    }

    /// Removes the page locally (not interested / blocked / deleted / reported).
    func remove(where predicate: (FeedItem) -> Bool) {
        let removed = items.values.filter(predicate).map(\.id)
        guard !removed.isEmpty else { return }
        removed.forEach { app?.players.release($0); items[$0] = nil }
        pages.removeAll { if case let .video(id) = $0 { return removed.contains(id) }; return false }
        if activeIndex >= pages.count { activeIndex = max(0, pages.count - 1) }
        activate()
    }

    func notInterested(_ id: UUID) {
        guard let app, let it = items[id] else { return }
        app.recordInterest(.notInterested, video: it.video)
        remove { $0.id == id }
        app.show("Будем показывать такое реже")
    }

    func block(authorOf id: UUID) {
        guard let app, let it = items[id] else { return }
        app.requireAccount {
            Task {
                do {
                    try await app.backend.setBlocked(true, userID: it.author.id)
                    remove { $0.author.id == it.author.id }
                    app.show("@\(it.author.username) заблокирован(а)", style: .success)
                } catch { app.show(error) }
            }
        }
    }

    func delete(_ id: UUID) {
        guard let app else { return }
        Task {
            do {
                try await app.backend.deleteVideo(id: id)
                remove { $0.id == id }
                app.contentVersion += 1
                await app.refreshCurrentUser()
                app.show("Ролик удалён", style: .success)
            } catch { app.show(error) }
        }
    }

    func isMine(_ it: FeedItem) -> Bool { app?.session?.userID == it.author.id && app?.isGuest == false }
}

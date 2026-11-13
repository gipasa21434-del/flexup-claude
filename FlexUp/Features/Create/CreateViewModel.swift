import SwiftUI
import AVFoundation
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import FlexCore

/// A video imported from the photo library into our sandbox.
struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = MediaStore.exportsDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

@MainActor
final class CreateViewModel: ObservableObject {
    enum Step { case source, edit, details }
    enum Phase: Equatable {
        case idle
        case processing(Double)
        case uploading(Double)
        case done
        case failed(String)
    }

    @Published var step: Step = .source
    @Published var sourceURL: URL?
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var coverTime: Double = 0
    @Published var coverImage: UIImage?
    @Published var filmstrip: [UIImage] = []
    @Published var caption = ""
    @Published var mood: Mood?
    @Published var visibility: VideoVisibility = .everyone
    @Published var joinChallenge = true
    @Published var composeDuo = true
    @Published var phase: Phase = .idle
    @Published var importing = false
    @Published var importError: String?
    @Published var tagSuggestions: [String] = []

    let context: ComposeContext
    private var publishTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?

    init(context: ComposeContext) {
        self.context = context
        if let ch = context.challenge { caption = "#\(ch.tag) " }
        if let r = context.replyTo { caption = "Моя реакция на @\(r.author.username) #duoreact " }
    }

    var selectedDuration: Double { max(0, trimEnd - trimStart) }
    var isTooLong: Bool { selectedDuration > VideoProcessing.maxDuration + 0.05 }
    var captionError: String? { Validator.text(caption, limit: Validator.captionLimit, allowEmpty: true)?.errorDescription }
    var canPublish: Bool { sourceURL != nil && !isTooLong && selectedDuration >= 1 && captionError == nil && !isBusy }
    var isBusy: Bool {
        switch phase { case .processing, .uploading: return true; default: return false }
    }

    // MARK: Import

    func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importing = true
        importError = nil
        defer { importing = false }
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                importError = "Не удалось загрузить видео из медиатеки."
                return
            }
            await use(url: picked.url)
        } catch {
            importError = "Не удалось импортировать видео: \(error.localizedDescription)"
        }
    }

    func useDemoClip() async {
        guard let bundled = MediaStore.url(for: .bundled("demo_pulse")) else { return }
        let dest = MediaStore.exportsDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try? FileManager.default.copyItem(at: bundled, to: dest)
        await use(url: dest)
    }

    func use(url: URL) async {
        do {
            let d = try await VideoProcessing.duration(of: url)
            guard d > 0.5 else { importError = "Видео слишком короткое или повреждено."; return }
            sourceURL = url
            duration = d
            trimStart = 0
            trimEnd = min(d, VideoProcessing.maxDuration)
            coverTime = min(1, trimEnd / 2)
            step = .edit
            refreshCover()
            filmstrip = await VideoProcessing.filmstrip(of: url, count: 8)
        } catch {
            importError = "Не получилось прочитать видео: \(error.localizedDescription)"
        }
    }

    func refreshCover() {
        guard let url = sourceURL else { return }
        coverTask?.cancel()
        let t = min(max(coverTime, trimStart), trimEnd)
        coverTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000) // debounce slider
            guard !Task.isCancelled else { return }
            if let img = try? await VideoProcessing.cover(of: url, at: t) { coverImage = img }
        }
    }

    // MARK: Caption helpers

    func updateTagSuggestions(trending: [String]) {
        guard let partial = HashtagParser.trailingPartialTag(in: caption) else { tagSuggestions = []; return }
        let pool = trending + Mood.allCases.flatMap { $0.relatedTags }.sorted()
        var out: [String] = []
        for t in pool where (partial.isEmpty || t.hasPrefix(partial)) && t != partial && !out.contains(t) { out.append(t) }
        tagSuggestions = Array(out.prefix(8))
    }

    func applySuggestion(_ tag: String) {
        guard let hash = caption.lastIndex(of: "#") else { return }
        caption = String(caption[..<hash]) + "#\(tag) "
        tagSuggestions = []
    }

    // MARK: Publish

    func publish(app: AppModel, onDone: @escaping () -> Void) {
        guard canPublish, let source = sourceURL else { return }
        publishTask?.cancel()
        publishTask = Task {
            do {
                phase = .processing(0)
                // 1) Trim (always re-encode → consistent H.264 MP4 for streaming).
                var fileURL = try await VideoProcessing.trim(source, start: trimStart, end: trimEnd) { [weak self] p in
                    self?.phase = .processing(p * (self?.shouldComposeDuo == true ? 0.5 : 1))
                }
                // 2) DUO REACT: stack original + reaction into one video.
                if shouldComposeDuo, let original = context.replyTo, let originalURL = MediaStore.url(for: original.video.source) {
                    fileURL = try await VideoProcessing.composeDuo(original: originalURL, reaction: fileURL) { [weak self] p in
                        self?.phase = .processing(0.5 + p * 0.5)
                    }
                }
                try Task.checkCancellation()
                let finalDuration = (try? await VideoProcessing.duration(of: fileURL)) ?? selectedDuration
                let cover = try? await VideoProcessing.cover(of: fileURL, at: max(0, coverTime - trimStart))
                phase = .uploading(0)
                let challengeTag = (joinChallenge ? context.challenge?.tag : nil)
                let request = PublishRequest(fileURL: fileURL,
                                             coverJPEG: (cover ?? coverImage)?.jpegData(compressionQuality: 0.8),
                                             caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                             mood: mood, visibility: visibility, challengeTag: challengeTag,
                                             replyToVideoID: context.replyTo?.id, duration: finalDuration)
                _ = try await app.backend.publish(request) { p in
                    Task { @MainActor [weak self] in
                        if case .uploading = self?.phase { self?.phase = .uploading(p) }
                    }
                }
                try? FileManager.default.removeItem(at: fileURL)
                phase = .done
                Haptics.success()
                app.record(.published(challenge: challengeTag != nil))
                app.contentVersion += 1
                await app.refreshCurrentUser()
                app.show(app.isDemo ? "Опубликовано (демо: файл сохранён на устройстве)" : "Ролик опубликован!", style: .success)
                onDone()
            } catch is CancellationError {
                phase = .idle
            } catch VideoProcessingError.cancelled {
                phase = .idle
            } catch BackendError.cancelled {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
                Haptics.error()
            }
        }
    }

    var shouldComposeDuo: Bool { context.replyTo != nil && composeDuo }

    func cancelPublish() {
        publishTask?.cancel()
        publishTask = nil
        phase = .idle
    }

    func cleanup() {
        publishTask?.cancel()
        coverTask?.cancel()
        if let u = sourceURL, u.path.hasPrefix(MediaStore.exportsDirectory.path) { try? FileManager.default.removeItem(at: u) }
    }
}

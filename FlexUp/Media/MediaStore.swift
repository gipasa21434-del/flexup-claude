import Foundation
import UIKit
import AVFoundation
import FlexCore

/// Resolves `VideoSource` values to playable URLs and owns on-device media folders.
enum MediaStore {
    static let demoFolder = "DemoMedia"
    /// Optional folder with the developer's own test clips (git-ignored, bundled only if present at build time).
    static let localTestFolder = "LocalTestMedia"
    static let localTestPrefix = "local-test/"

    /// Videos found in `LocalTestMedia/` inside the app bundle, shown in demo mode for manual testing.
    static func localTestVideos(now: Date = Date()) -> [Video] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "mp4", subdirectory: localTestFolder) else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.enumerated().map { i, url in
            let name = url.deletingPathExtension().lastPathComponent
            let mood = Mood.allCases[i % Mood.allCases.count]
            return Video(id: stableID(for: name), authorID: DemoContent.demoUserID(2 + i % 5),
                         caption: "Тестовое видео \(i + 1) #localtest #\(mood.relatedTags.sorted().first ?? "тест")",
                         musicTitle: "Оригинальный звук", mood: mood, duration: 15,
                         source: .bundled(localTestPrefix + name), thumbnail: nil,
                         likesCount: 100 * (i + 1), commentsCount: 3 * i, savesCount: 5 * i, sharesCount: i,
                         viewsCount: 1_000 * (i + 2), createdAt: now.addingTimeInterval(-Double(i) * 1_800), isDemo: true)
        }
    }

    /// Deterministic UUID from a file name, so likes/comments survive relaunches.
    static func stableID(for name: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in name.utf8 { h1 = (h1 ^ UInt64(b)) &* 0x100000001b3; h2 = (h2 ^ UInt64(b)) &* 0x100000001b3 &+ 7 }
        let hex = String(format: "%016llx%016llx", h1, h2)
        let chars = Array(hex)
        let s = "\(String(chars[0..<8]))-\(String(chars[8..<12]))-4\(String(chars[13..<16]))-8\(String(chars[17..<20]))-\(String(chars[20..<32]))"
        return UUID(uuidString: s) ?? UUID()
    }

    static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // User-generated files must not end up in iCloud backups twice; they are re-creatable in demo.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(values)
        return dir
    }

    static var exportsDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for source: VideoSource) -> URL? {
        switch source {
        case let .bundled(name) where name.hasPrefix(localTestPrefix):
            return Bundle.main.url(forResource: String(name.dropFirst(localTestPrefix.count)), withExtension: "mp4",
                                   subdirectory: localTestFolder)
        case let .bundled(name):
            return Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: demoFolder)
                ?? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: demoFolder)
        case let .local(name):
            let url = mediaDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case let .remote(url):
            return url.scheme == "about" ? nil : url
        }
    }

    static func thumbnailURL(for source: VideoSource) -> URL? {
        if case let .bundled(name) = source, !name.hasPrefix(localTestPrefix) {
            return Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: demoFolder)
        }
        return url(for: source)
    }

    // MARK: Cache accounting (Settings → «Кэш»)

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func cacheSize() -> Int64 {
        Int64(URLCache.shared.currentDiskUsage) + directorySize(exportsDirectory)
    }

    static func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: exportsDirectory)
        ImageLoader.shared.purge()
    }
}

/// Small image loader with an in-memory LRU (NSCache) + URLCache for remote images.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        cache.countLimit = 150
        cache.totalCostLimit = 60 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    func purge() { cache.removeAllObjects() }

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        var image: UIImage?
        if url.isFileURL {
            if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                image = await Self.frame(of: url, at: 1)
            } else {
                image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            }
        } else if let (data, _) = try? await session.data(from: url) {
            image = await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() }.value
        }
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * 4))
        }
        return image
    }

    static func frame(of url: URL, at seconds: Double) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        guard let cg = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: cg)
    }
}

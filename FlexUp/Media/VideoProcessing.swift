import AVFoundation
import UIKit
import FlexCore

enum VideoProcessingError: LocalizedError {
    case noVideoTrack, exportFailed(String), cancelled, tooLong(Double)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "В файле нет видеодорожки."
        case let .exportFailed(m): return "Не удалось обработать видео: \(m)"
        case .cancelled: return "Обработка отменена."
        case let .tooLong(max): return "Выбери фрагмент не длиннее \(Int(max)) секунд."
        }
    }
}

/// Basic, honest editing tools: trimming a fragment, picking a cover frame and DUO REACT stacking.
/// No filters/effects timeline — that is intentionally out of scope.
enum VideoProcessing {
    static let maxDuration: Double = 60

    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration)
        return d.seconds.isFinite ? d.seconds : 0
    }

    static func cover(of url: URL, at seconds: Double, maxSize: CGFloat = 720) async throws -> UIImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cg = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        return UIImage(cgImage: cg)
    }

    /// Frames for the trim timeline.
    static func filmstrip(of url: URL, count: Int) async -> [UIImage] {
        guard let d = try? await duration(of: url), d > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        var out: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { out.append(UIImage(cgImage: cg)) }
        }
        return out
    }

    /// Exports [start, end] to an H.264 MP4 suitable for upload. Reports progress, supports Task cancellation.
    static func trim(_ url: URL, start: Double, end: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        guard end - start <= maxDuration + 0.05 else { throw VideoProcessingError.tooLong(maxDuration) }
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        return try await export(asset: asset, timeRange: range, videoComposition: nil, audioMix: nil, progress: progress)
    }

    static func export(asset: AVAsset, timeRange: CMTimeRange?, videoComposition: AVVideoComposition?,
                       audioMix: AVAudioMix?, progress: @escaping (Double) -> Void) async throws -> URL {
        let preset = AVAssetExportPreset1280x720
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoProcessingError.exportFailed("экспорт недоступен")
        }
        let out = MediaStore.exportsDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        session.videoComposition = videoComposition
        session.audioMix = audioMix

        let box = ExportBox(session: session)
        return try await withTaskCancellationHandler {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(box.session.progress))
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer { poll.cancel() }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { c.resume() }
            }
            switch box.session.status {
            case .completed:
                await MainActor.run { progress(1) }
                return out
            case .cancelled:
                throw VideoProcessingError.cancelled
            default:
                throw VideoProcessingError.exportFailed(box.session.error?.localizedDescription ?? "неизвестная ошибка")
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// DUO REACT: stacks the original (top) and the reaction (bottom) into one 720×1280 video.
    /// Reaction audio at full volume, original audio quieter. Duration = the shorter of the two.
    static func composeDuo(original: URL, reaction: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let oAsset = AVURLAsset(url: original)
        let rAsset = AVURLAsset(url: reaction)
        guard let oVideo = try await oAsset.loadTracks(withMediaType: .video).first,
              let rVideo = try await rAsset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessingError.noVideoTrack
        }
        let oDuration = try await oAsset.load(.duration)
        let rDuration = try await rAsset.load(.duration)
        let duration = CMTimeMinimum(CMTimeMinimum(oDuration, rDuration), CMTime(seconds: maxDuration, preferredTimescale: 600))
        let range = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let top = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let bottom = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessingError.exportFailed("не удалось создать дорожки")
        }
        try top.insertTimeRange(range, of: oVideo, at: .zero)
        try bottom.insertTimeRange(range, of: rVideo, at: .zero)

        var mixParams: [AVMutableAudioMixInputParameters] = []
        for (asset, volume) in [(oAsset, Float(0.35)), (rAsset, Float(1.0))] {
            if let a = try await asset.loadTracks(withMediaType: .audio).first,
               let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(range, of: a, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(volume, at: .zero)
                mixParams.append(p)
            }
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        let render = CGSize(width: 720, height: 1280)
        let half = CGRect(x: 0, y: 0, width: render.width, height: render.height / 2)

        func layer(for track: AVMutableCompositionTrack, source: AVAssetTrack, yOffset: CGFloat) async throws -> AVMutableVideoCompositionLayerInstruction {
            let natural = try await source.load(.naturalSize)
            let pref = try await source.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: natural).applying(pref)
            let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            // Aspect-fill into the half-screen slot, centred.
            let scale = max(half.width / size.width, half.height / size.height)
            let tx = (half.width - size.width * scale) / 2
            let ty = (half.height - size.height * scale) / 2 + yOffset
            let normalise = pref.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            let transform = normalise.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            instruction.setTransform(transform, at: .zero)
            // Crop the overflow so each video stays inside its own half. The crop rect lives in the
            // track's natural coordinate space, so map the visible slot back through the inverse transform.
            let visibleOriented = CGRect(x: -tx / scale, y: (yOffset - ty) / scale,
                                         width: half.width / scale, height: half.height / scale)
            let visibleNatural = visibleOriented.applying(normalise.inverted())
            instruction.setCropRectangle(visibleNatural.standardized.integral, at: .zero)
            return instruction
        }

        let main = AVMutableVideoCompositionInstruction()
        main.timeRange = range
        main.backgroundColor = UIColor(hex: 0x0E0F13).cgColor
        main.layerInstructions = [
            try await layer(for: top, source: oVideo, yOffset: 0),
            try await layer(for: bottom, source: rVideo, yOffset: half.height)
        ]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = render
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [main]

        return try await export(asset: composition, timeRange: nil, videoComposition: videoComposition,
                                audioMix: audioMix, progress: progress)
    }
}

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(session: AVAssetExportSession) { self.session = session }
}

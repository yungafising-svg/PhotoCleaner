import Foundation
import Photos
import AVFoundation
import CoreImage
import UIKit
import ImageIO

/// Работа с видео внутри Live Photo: поиск лучшего кадра и замена титульного
enum LiveFrames {
    static func err(_ text: String) -> NSError {
        NSError(domain: "PhotoCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Сохраняет видео Live Photo во временный файл
    static func pairedVideoURL(_ asset: PHAsset, network: Bool) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { $0.type == .pairedVideo })
                ?? resources.first(where: { $0.type == .fullSizePairedVideo }) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = network
        do {
            try await PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts)
            return url
        } catch {
            return nil
        }
    }

    /// Перебирает кадры видео и возвращает лучший, если он заметно лучше текущего титульного
    static func bestFrame(for info: PhotoInfo, samples: Int = 15) async -> LiveFix? {
        guard let url = await pairedVideoURL(info.asset, network: false) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        let av = AVURLAsset(url: url)
        guard let duration = (try? await av.load(.duration))?.seconds, duration > 0 else { return nil }

        let gen = AVAssetImageGenerator(asset: av)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 512, height: 512)   // тот же масштаб, что и при оценке фото
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        var bestImage: CGImage?
        var bestTime = 0.0
        var bestScore = -Double.infinity
        for k in 0..<samples {
            let t = duration * (Double(k) + 0.5) / Double(samples)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let s = Analyzer.score(Analyzer.measure(cg, orientation: .up))
            if s > bestScore {
                bestScore = s
                bestTime = t
                bestImage = cg
            }
        }
        let current = Analyzer.score(info.m)
        guard let img = bestImage, bestScore > current + 0.15 else { return nil }
        return LiveFix(id: info.id, time: bestTime, preview: UIImage(cgImage: img),
                       oldScore: current, newScore: bestScore)
    }

    /// Готовит правку: титульный кадр заменяется кадром из видео, фото остаётся живым
    static func prepare(_ fix: LiveFix, asset: PHAsset) async throws -> PHContentEditingOutput {
        guard let url = await pairedVideoURL(asset, network: true) else {
            throw LiveFrames.err("Не удалось получить видео живого фото")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let frame = try await gen.image(at: CMTime(seconds: fix.time, preferredTimescale: 600)).image

        let input = try await editingInput(asset)
        guard let ctx = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
            throw LiveFrames.err("Не удалось открыть живое фото для правки")
        }

        // Кадр из видео уже повёрнут правильно, а титульный кадр хранится "сырым" —
        // приводим к той же ориентации
        let raw = CIImage(cgImage: frame).oriented(inverse(ctx.orientation))

        ctx.frameProcessor = { liveFrame, _ in
            guard liveFrame.type == .photo else { return liveFrame.image }
            let target = liveFrame.image.extent
            let src = raw.extent
            guard src.width > 0, src.height > 0 else { return liveFrame.image }
            return raw
                .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
                .transformed(by: CGAffineTransform(scaleX: target.width / src.width,
                                                   y: target.height / src.height))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        }

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.egor.photocleaner.keyframe",
                                                 formatVersion: "1.0",
                                                 data: Data(String(fix.time).utf8))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.saveLivePhoto(to: output, options: nil) { ok, error in
                if ok { cont.resume() } else { cont.resume(throwing: error ?? LiveFrames.err("Не удалось сохранить кадр")) }
            }
        }
        return output
    }

    static func editingInput(_ asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHContentEditingInputRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: opts) { input, info in
                if let input {
                    cont.resume(returning: input)
                } else {
                    let e = info[PHContentEditingInputErrorKey] as? Error
                    cont.resume(throwing: e ?? LiveFrames.err("Нет доступа к фото"))
                }
            }
        }
    }

    static func inverse(_ o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .left: return .right
        case .right: return .left
        default: return o
        }
    }
}

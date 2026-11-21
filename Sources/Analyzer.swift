import Foundation
import Photos
import UIKit
import Vision
import ImageIO

enum ImageLoader {
    /// Загружает картинку с длинной стороной ~side пикселей
    static func image(for asset: PHAsset, side: CGFloat, network: Bool) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat   // колбэк вызывается ровно один раз
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = network
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                cont.resume(returning: image)
            }
        }
    }
}

enum Analyzer {
    static func analyze(_ asset: PHAsset) async -> PhotoInfo? {
        guard let ui = await ImageLoader.image(for: asset, side: 512, network: false),
              let cg = ui.cgImage else { return nil }

        var info = PhotoInfo(
            id: asset.localIdentifier,
            asset: asset,
            date: asset.creationDate,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )

        // Резкость и экспозиция
        if let g = Gray(cg, maxSide: 512) {
            info.sharpness = g.laplacianVariance()
            let e = g.exposure()
            info.brightness = e.mean
            info.clipped = e.clipped
        }
        info.dHash = dHash(cg)

        let handler = VNImageRequestHandler(cgImage: cg,
                                            orientation: CGImagePropertyOrientation(ui.imageOrientation),
                                            options: [:])

        // "Отпечаток" изображения для поиска похожих
        let fpReq = VNGenerateImageFeaturePrintRequest()
        fpReq.revision = VNGenerateImageFeaturePrintRequestRevision2
        if (try? handler.perform([fpReq])) != nil {
            info.featurePrint = fpReq.results?.first
        }

        // Качество лиц (закрытые глаза, смаз, неудачный ракурс)
        let faceReq = VNDetectFaceCaptureQualityRequest()
        if (try? handler.perform([faceReq])) != nil,
           let faces = faceReq.results, !faces.isEmpty {
            info.faceQuality = faces.compactMap { $0.faceCaptureQuality }.max().map { Double($0) }
        }

        info.score = score(info)
        return info
    }

    static func score(_ i: PhotoInfo) -> Double {
        var s = min(1, log10(1 + i.sharpness) / 3)
        if i.brightness < 40 || i.brightness > 220 { s -= 0.3 }
        s -= i.clipped * 0.5
        if let fq = i.faceQuality { s += fq }
        return s
    }

    /// Разностный хэш 64 бита — ловит точные копии
    static func dHash(_ cg: CGImage) -> UInt64 {
        var px = [UInt8](repeating: 0, count: 9 * 8)
        px.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: 9, height: 8,
                                   bitsPerComponent: 8, bytesPerRow: 9,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            }
        }
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                h <<= 1
                if px[y * 9 + x] < px[y * 9 + x + 1] { h |= 1 }
            }
        }
        return h
    }
}

/// Серое уменьшенное изображение для быстрых расчётов
struct Gray {
    let px: [UInt8]
    let w: Int
    let h: Int

    init?(_ cg: CGImage, maxSide: Int) {
        let s = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
        let width = max(16, Int(Double(cg.width) * s))
        let height = max(16, Int(Double(cg.height) * s))
        var buf = [UInt8](repeating: 0, count: width * height)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        px = buf
        w = width
        h = height
    }

    func laplacianVariance() -> Double {
        let w = self.w, h = self.h
        return px.withUnsafeBufferPointer { p -> Double in
            var sum = 0.0, sq = 0.0, n = 0.0
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let i = row + x
                    let v = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1]) - Int(p[i - w]) - Int(p[i + w])
                    let d = Double(v)
                    sum += d
                    sq += d * d
                    n += 1
                }
            }
            guard n > 0 else { return 0 }
            let m = sum / n
            return sq / n - m * m
        }
    }

    func exposure() -> (mean: Double, clipped: Double) {
        var s = 0, c = 0
        for v in px {
            s += Int(v)
            if v < 8 || v > 247 { c += 1 }
        }
        let n = Double(max(px.count, 1))
        return (Double(s) / n, Double(c) / n)
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

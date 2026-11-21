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
    /// Полный анализ одного фото (результат кэшируется)
    static func analyze(_ asset: PHAsset) async -> CacheEntry? {
        guard let ui = await ImageLoader.image(for: asset, side: 512, network: false),
              let cg = ui.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(ui.imageOrientation)
        let m = measure(cg, orientation: orientation)

        // "Отпечаток" изображения для поиска похожих
        var fpData: Data?
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        let fpReq = VNGenerateImageFeaturePrintRequest()
        fpReq.revision = VNGenerateImageFeaturePrintRequestRevision2
        if (try? handler.perform([fpReq])) != nil, let fp = fpReq.results?.first {
            fpData = try? NSKeyedArchiver.archivedData(withRootObject: fp, requiringSecureCoding: true)
        }
        return CacheEntry(modified: asset.modificationDate,
                          bytes: fileSize(asset),
                          metrics: m,
                          dHash: dHash(cg),
                          featurePrint: fpData)
    }

    /// Размер фото на диске (вместе с видео Live Photo)
    static func fileSize(_ asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for r in PHAssetResource.assetResources(for: asset) {
            if let n = r.value(forKey: "fileSize") as? NSNumber { total += n.int64Value }
        }
        return total > 0 ? total : Int64(asset.pixelWidth * asset.pixelHeight / 4)
    }

    /// Резкость, экспозиция и качество лиц одного кадра
    static func measure(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> Metrics {
        var m = Metrics()
        if let g = Gray(cg, maxSide: 512) {
            let sh = g.sharpness()
            m.sharpness = sh.subject
            m.globalSharpness = sh.global
            let e = g.exposure()
            m.brightness = e.mean
            m.clipped = e.clipped
        }
        // Качество лиц (закрытые глаза, смаз, неудачный ракурс)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        let faceReq = VNDetectFaceCaptureQualityRequest()
        if (try? handler.perform([faceReq])) != nil,
           let faces = faceReq.results, !faces.isEmpty {
            m.faceQuality = faces.compactMap { $0.faceCaptureQuality }.max().map { Double($0) }
        }
        return m
    }

    /// Оценка качества кадра: чем больше, тем лучше
    static func score(_ m: Metrics) -> Double {
        var s = min(1, log10(1 + m.sharpness) / 3)
        if m.brightness < 40 || m.brightness > 220 { s -= 0.3 }
        s -= m.clipped * 0.5
        if let fq = m.faceQuality { s += fq * 1.2 }
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

    /// Резкость: всего кадра и самого резкого участка (сетка 4×4).
    /// Портрет с размытым фоном не считается размытым — смотрим на объект.
    func sharpness(tiles n: Int = 4) -> (global: Double, subject: Double) {
        let w = self.w
        let h = self.h
        let p = px
        var ts = [Double](repeating: 0, count: n * n)
        var tq = [Double](repeating: 0, count: n * n)
        var tc = [Double](repeating: 0, count: n * n)
        var s = 0.0
        var q = 0.0
        var c = 0.0
        for y in 1..<(h - 1) {
            let row = y * w
            let ty = min(n - 1, y * n / h)
            for x in 1..<(w - 1) {
                let i = row + x
                let center: Int = 4 * Int(p[i])
                let horiz: Int = Int(p[i - 1]) + Int(p[i + 1])
                let vert: Int = Int(p[i - w]) + Int(p[i + w])
                let v = Double(center - horiz - vert)
                let k = ty * n + min(n - 1, x * n / w)
                ts[k] += v
                tq[k] += v * v
                tc[k] += 1
                s += v
                q += v * v
                c += 1
            }
        }
        var tiles: [Double] = []
        for k in 0..<(n * n) { tiles.append(Gray.variance(ts[k], tq[k], tc[k])) }
        tiles.sort(by: >)
        let subject = (tiles[0] + tiles[min(1, tiles.count - 1)]) / 2
        return (Gray.variance(s, q, c), subject)
    }

    static func variance(_ s: Double, _ q: Double, _ c: Double) -> Double {
        guard c > 0 else { return 0 }
        let mean = s / c
        return q / c - mean * mean
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

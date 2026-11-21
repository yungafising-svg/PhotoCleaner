import Foundation
import Vision

enum Classifier {
    static func classify(_ infos: [PhotoInfo], _ t: Thresholds) -> Results {
        var r = Results()
        let sorted = infos.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var uf = UnionFind(sorted.count)
        let thr = Float(t.similar)

        func dist(_ a: PhotoInfo, _ b: PhotoInfo) -> Float? {
            guard let fa = a.featurePrint, let fb = b.featurePrint else { return nil }
            var d: Float = 0
            do { try fa.computeDistance(&d, to: fb) } catch { return nil }
            return d
        }

        // 1. Похожие: сравниваем соседние по времени кадры (серии, до 30 минут)
        for i in 0..<sorted.count {
            var j = i + 1
            while j < sorted.count && j - i <= 40 {
                if let da = sorted[i].date, let db = sorted[j].date,
                   db.timeIntervalSince(da) > 1800 { break }
                if let d = dist(sorted[i], sorted[j]), d < thr { uf.union(i, j) }
                j += 1
            }
        }

        // 2. Точные копии в любом месте галереи (сохранённые повторно, из мессенджеров)
        var byHash: [UInt64: Int] = [:]
        for (i, p) in sorted.enumerated() where p.dHash != 0 && p.dHash != UInt64.max {
            if let k = byHash[p.dHash] {
                if (dist(sorted[k], p) ?? 0) < thr { uf.union(k, i) }
            } else {
                byHash[p.dHash] = i
            }
        }

        var comps: [Int: [Int]] = [:]
        for i in 0..<sorted.count { comps[uf.find(i), default: []].append(i) }

        let groups = comps.values
            .filter { $0.count > 1 }
            .sorted { ($0.max() ?? 0) > ($1.max() ?? 0) }   // свежие сверху
        r.groups = groups.map { idxs in
            idxs.map { sorted[$0] }.sorted { $0.score > $1.score }.map(\.id)
        }

        // Неудачные кадры (скриншоты не трогаем)
        let normal = infos.filter { !$0.isScreenshot }
        let byDateDesc: (PhotoInfo, PhotoInfo) -> Bool = {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
        r.blurry = normal.filter { $0.sharpness < t.blur }
            .sorted { $0.sharpness < $1.sharpness }.map(\.id)
        r.badExposure = normal.filter { $0.brightness < t.dark || $0.brightness > t.bright }
            .sorted(by: byDateDesc).map(\.id)
        r.badFaces = normal.filter { ($0.faceQuality ?? 1) < t.face }
            .sorted { ($0.faceQuality ?? 1) < ($1.faceQuality ?? 1) }.map(\.id)
        r.screenshots = infos.filter(\.isScreenshot).sorted(by: byDateDesc).map(\.id)
        return r
    }
}

struct UnionFind {
    var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

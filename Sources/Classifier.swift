import Foundation
import Vision

enum Classifier {
    static func classify(_ infos: [PhotoInfo], _ t: Thresholds, notDuplicate: Set<String>) -> Results {
        var r = Results()
        let sorted = infos.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var uf = UnionFind(sorted.count)
        let thr = Float(t.similar)
        // Скриншоты объединяем только если это точная копия: похожие скриншоты
        // (переписка, чеки, билеты) могут отличаться важной информацией.
        let screenshotThr: Float = 0.05

        func dist(_ a: PhotoInfo, _ b: PhotoInfo) -> Float? {
            guard let fa = a.featurePrint, let fb = b.featurePrint else { return nil }
            var d: Float = 0
            do { try fa.computeDistance(&d, to: fb) } catch { return nil }
            return d
        }
        func ignored(_ i: Int, _ j: Int) -> Bool {
            notDuplicate.contains(pairKey(sorted[i].id, sorted[j].id))
        }
        func limit(_ a: PhotoInfo, _ b: PhotoInfo) -> Float {
            (a.isScreenshot || b.isScreenshot) ? screenshotThr : thr
        }

        // 1. Серии: соседние по времени кадры (до 30 минут) с похожим содержимым
        for i in 0..<sorted.count {
            var j = i + 1
            while j < sorted.count && j - i <= 40 {
                if let da = sorted[i].date, let db = sorted[j].date,
                   db.timeIntervalSince(da) > 1800 { break }
                if !ignored(i, j), let d = dist(sorted[i], sorted[j]), d < limit(sorted[i], sorted[j]) {
                    uf.union(i, j)
                }
                j += 1
            }
        }

        // 2. Копии в любом месте галереи (пересохранённые, из мессенджеров, скачанные).
        //    Хэши, отличающиеся не больше чем на 3 бита, ищем через 4 корзины по 16 бит.
        var buckets = [[UInt16: [Int]]](repeating: [:], count: 4)
        for (i, p) in sorted.enumerated() where p.dHash != 0 && p.dHash != UInt64.max {
            var candidates = Set<Int>()
            for c in 0..<4 {
                let key = UInt16(truncatingIfNeeded: p.dHash >> (UInt64(c) * 16))
                if let list = buckets[c][key] { candidates.formUnion(list) }
            }
            for k in candidates where (sorted[k].dHash ^ p.dHash).nonzeroBitCount <= 3 {
                let d = dist(sorted[k], p) ?? 1
                if !ignored(k, i), d < limit(sorted[k], p) { uf.union(k, i) }
            }
            for c in 0..<4 {
                let key = UInt16(truncatingIfNeeded: p.dHash >> (UInt64(c) * 16))
                if buckets[c][key, default: []].count < 300 { buckets[c][key, default: []].append(i) }
            }
        }

        var comps: [Int: [Int]] = [:]
        for i in 0..<sorted.count { comps[uf.find(i), default: []].append(i) }
        r.groups = comps.values
            .filter { $0.count > 1 }
            .map { idxs in idxs.map { sorted[$0] }.sorted { $0.score > $1.score }.map(\.id) }

        // Случайные кадры: почти чёрные или белые снимки без деталей и без людей
        // (снято в кармане, пальцем на объективе). Обычные неудачные, но единственные
        // фото не предлагаем — это память.
        r.accidental = infos.filter { p in
            !p.isScreenshot && p.m.faceQuality == nil && p.m.sharpness < 30
                && (p.m.brightness < 25 || p.m.brightness > 235)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        .map(\.id)
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

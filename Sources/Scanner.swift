import Foundation
import Photos
import SwiftUI
import Vision

@MainActor
final class Scanner: ObservableObject {
    enum Phase { case idle, scanning, done }

    @Published var auth: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var processed = 0
    @Published var total = 0
    @Published var skipped = 0
    @Published var stage = ""
    @Published var lastError: String?

    @Published var photos: [String: PhotoInfo] = [:]
    @Published var groups: [[String]] = []          // первый в группе — лучший
    @Published var blurry: [String] = []
    @Published var badExposure: [String] = []
    @Published var badFaces: [String] = []
    @Published var screenshots: [String] = []
    @Published var liveFixes: [String: LiveFix] = [:]
    @Published var decisions = Store.loadDecisions()

    private var cache: [String: CacheEntry] = Store.loadCache()
    private var task: Task<Void, Never>?

    // MARK: - Защита и видимость

    /// Фото, которые приложение само никогда не предложит удалить
    func isProtected(_ id: String) -> Bool {
        if decisions.protected.contains(id) { return true }
        guard let p = photos[id] else { return false }
        if p.isFavorite { return true }
        if Prefs.protectAlbums && p.inAlbum { return true }
        if Prefs.protectEdited && p.isEdited { return true }
        return false
    }

    /// Что показывать в списках неудачных: без защищённых и без живых фото, которые можно исправить
    func visible(_ ids: [String]) -> [String] {
        ids.filter { liveFixes[$0] == nil && !isProtected($0) }
    }

    func inTrash(_ id: String) -> Bool { decisions.trash.contains(id) }

    /// Сколько места освободит группа, если оставить лучший
    func reclaimable(_ group: [String]) -> Int64 {
        group.dropFirst().filter { !isProtected($0) }.reduce(0) { $0 + (photos[$1]?.bytes ?? 0) }
    }

    var reclaimableTotal: Int64 { groups.reduce(0) { $0 + reclaimable($1) } }

    var trashBytes: Int64 {
        decisions.trash.reduce(0) { $0 + (photos[$1]?.bytes ?? 0) }
    }

    // MARK: - Сканирование

    func requestAccess() async {
        auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func start(limit: Int?) {
        task?.cancel()
        task = Task { await run(limit: limit) }
    }

    func cancel() { task?.cancel() }

    private func run(limit: Int?) async {
        phase = .scanning
        progress = 0; processed = 0; skipped = 0
        stage = "Готовлю список фото"
        liveFixes = [:]

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit { opts.fetchLimit = limit }
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        let albumIDs = Self.userAlbumAssetIDs()

        // Уже проанализированные и не изменённые фото берём из кэша
        var entries: [String: CacheEntry] = [:]
        var toAnalyze: [PHAsset] = []
        for a in assets {
            if let c = cache[a.localIdentifier], c.modified == a.modificationDate {
                entries[a.localIdentifier] = c
            } else {
                toAnalyze.append(a)
            }
        }

        stage = "Анализирую новые фото"
        total = toAnalyze.count
        await withTaskGroup(of: (String, CacheEntry?).self) { group in
            var idx = 0
            let parallel = 4
            while idx < min(parallel, toAnalyze.count) {
                let a = toAnalyze[idx]; idx += 1
                group.addTask { (a.localIdentifier, await Analyzer.analyze(a)) }
            }
            while let result = await group.next() {
                let (id, entry) = result
                if let entry { entries[id] = entry; cache[id] = entry } else { skipped += 1 }
                processed += 1
                progress = Double(processed) / Double(max(total, 1))
                if Task.isCancelled { group.cancelAll(); break }
                if idx < toAnalyze.count {
                    let a = toAnalyze[idx]; idx += 1
                    group.addTask { (a.localIdentifier, await Analyzer.analyze(a)) }
                }
            }
        }

        let snapshot = cache
        Task.detached(priority: .utility) { Store.saveCache(snapshot) }

        var map: [String: PhotoInfo] = [:]
        for a in assets {
            guard let e = entries[a.localIdentifier] else { continue }
            map[a.localIdentifier] = Self.makeInfo(a, e, inAlbum: albumIDs.contains(a.localIdentifier))
        }
        photos = map
        // Корзина могла устареть (фото удалены в «Фото»)
        decisions.trash = decisions.trash.filter { map[$0] != nil || PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).count > 0 }

        await reclassify()
        if !Task.isCancelled { await findLiveFixes() }
        phase = .done
    }

    static func makeInfo(_ a: PHAsset, _ e: CacheEntry, inAlbum: Bool) -> PhotoInfo {
        let fp = e.featurePrint.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
        return PhotoInfo(id: a.localIdentifier,
                         asset: a,
                         date: a.creationDate,
                         isScreenshot: a.mediaSubtypes.contains(.photoScreenshot),
                         isLive: a.mediaSubtypes.contains(.photoLive),
                         isFavorite: a.isFavorite,
                         isEdited: a.hasAdjustments,
                         inAlbum: inAlbum,
                         bytes: e.bytes,
                         m: e.metrics,
                         dHash: e.dHash,
                         featurePrint: fp)
    }

    /// Все фото, которые лежат в альбомах пользователя
    static func userAlbumAssetIDs() -> Set<String> {
        var ids = Set<String>()
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        cols.enumerateObjects { c, _, _ in
            PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in
                ids.insert(a.localIdentifier)
            }
        }
        return ids
    }

    func reclassify() async {
        let snapshot = Array(photos.values)
        let t = Thresholds.current
        let notDup = decisions.notDuplicatePairs
        let r = await Task.detached(priority: .userInitiated) {
            Classifier.classify(snapshot, t, notDuplicate: notDup)
        }.value
        groups = r.groups.map(orderGroup).sorted { reclaimable($0) > reclaimable($1) }
        blurry = r.blurry
        badExposure = r.badExposure
        badFaces = r.badFaces
        screenshots = r.screenshots
    }

    /// Порядок в группе: выбранный вручную, затем по оценке
    func orderGroup(_ g: [String]) -> [String] {
        g.sorted { a, b in
            let pa = decisions.preferred.contains(a), pb = decisions.preferred.contains(b)
            if pa != pb { return pa }
            return (photos[a]?.score ?? 0) > (photos[b]?.score ?? 0)
        }
    }

    /// Почему этот кадр выбран лучшим
    func reason(for group: [String]) -> String {
        guard let best = group.first.flatMap({ photos[$0] }) else { return "" }
        if decisions.preferred.contains(best.id) { return "выбрано тобой" }
        let others = group.dropFirst().compactMap { photos[$0] }
        var r: [String] = []
        if best.isFavorite { r.append("в избранном") }
        if others.allSatisfy({ best.m.sharpness >= $0.m.sharpness }) { r.append("самое резкое") }
        if let fq = best.m.faceQuality, others.allSatisfy({ ($0.m.faceQuality ?? 0) <= fq }) {
            r.append("лучше лица")
        }
        if best.isEdited { r.append("отредактировано") }
        return r.isEmpty ? "лучшая общая оценка" : r.joined(separator: ", ")
    }

    // MARK: - Живые фото

    private func findLiveFixes() async {
        let bad = Set(blurry + badFaces + badExposure)
        let candidates = bad.compactMap { photos[$0] }.filter { $0.isLive }
        guard !candidates.isEmpty else { return }
        stage = "Ищу лучший кадр в живых фото"
        processed = 0
        total = candidates.count
        progress = 0
        var fixes: [String: LiveFix] = [:]
        for c in candidates {
            if Task.isCancelled { break }
            if let f = await LiveFrames.bestFrame(for: c) { fixes[f.id] = f }
            processed += 1
            progress = Double(processed) / Double(max(total, 1))
        }
        liveFixes = fixes
    }

    /// Делает найденные кадры титульными (iOS один раз спросит разрешение на изменение)
    func applyFixes(_ ids: [String]) async {
        var prepared: [(asset: PHAsset, output: PHContentEditingOutput, id: String)] = []
        for id in ids {
            guard let fix = liveFixes[id], let p = photos[id] else { continue }
            do {
                let out = try await LiveFrames.prepare(fix, asset: p.asset)
                prepared.append((p.asset, out, id))
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard !prepared.isEmpty else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for item in prepared {
                    PHAssetChangeRequest(for: item.asset).contentEditingOutput = item.output
                }
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        for item in prepared {
            let id = item.id
            liveFixes[id] = nil
            blurry.removeAll { $0 == id }
            badFaces.removeAll { $0 == id }
            badExposure.removeAll { $0 == id }
        }
    }

    // MARK: - Решения пользователя

    private func save() { Store.save(decisions) }

    func toggleTrash(_ id: String, force: Bool = false) {
        if decisions.trash.contains(id) {
            decisions.trash.remove(id)
        } else if force || !isProtected(id) {
            decisions.trash.insert(id)
        }
        save()
    }

    func addToTrash(_ ids: [String], force: Bool = false) {
        for id in ids where force || !isProtected(id) { decisions.trash.insert(id) }
        save()
    }

    func removeFromTrash(_ ids: [String]) {
        decisions.trash.subtract(ids)
        save()
    }

    /// Умная очистка: в корзину всё лишнее из групп похожих, кроме лучших и защищённых
    @discardableResult
    func smartCleanup() -> Int {
        var n = 0
        for g in groups {
            for id in g.dropFirst() where !isProtected(id) && !decisions.trash.contains(id) {
                decisions.trash.insert(id)
                n += 1
            }
        }
        save()
        return n
    }

    func toggleProtected(_ id: String) {
        if decisions.protected.contains(id) {
            decisions.protected.remove(id)
        } else {
            decisions.protected.insert(id)
            decisions.trash.remove(id)
        }
        save()
    }

    func setBest(_ id: String) {
        guard let gi = groups.firstIndex(where: { $0.contains(id) }) else { return }
        for other in groups[gi] { decisions.preferred.remove(other) }
        decisions.preferred.insert(id)
        decisions.trash.remove(id)
        save()
        groups[gi] = orderGroup(groups[gi])
    }

    func markNotDuplicates(_ group: [String]) {
        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                decisions.notDuplicatePairs.insert(pairKey(group[i], group[j]))
            }
        }
        decisions.trash.subtract(group)
        save()
        groups.removeAll { $0 == group }
    }

    func markSwipeReviewed(_ id: String, _ reviewed: Bool) {
        if reviewed { decisions.swipeReviewed.insert(id) } else { decisions.swipeReviewed.remove(id) }
        save()
    }

    func resetProtected() { decisions.protected = []; save() }

    func resetCache() {
        cache = [:]
        Store.clearCache()
    }

    /// Удаляет всё из корзины (iOS сама спросит подтверждение). Попадает в «Недавно удалённые».
    func emptyTrash() async -> Bool {
        let ids = Array(decisions.trash)
        guard !ids.isEmpty else { return true }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        let bytes = trashBytes
        if !assets.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
            } catch {
                return false
            }
        }
        let gone = Set(ids)
        for id in ids { photos[id] = nil; cache[id] = nil }
        groups = groups.map { $0.filter { !gone.contains($0) } }.filter { $0.count > 1 }
        blurry.removeAll { gone.contains($0) }
        badExposure.removeAll { gone.contains($0) }
        badFaces.removeAll { gone.contains($0) }
        screenshots.removeAll { gone.contains($0) }
        for id in ids { liveFixes[id] = nil }
        decisions.trash = []
        decisions.preferred.subtract(gone)
        decisions.freedBytes += bytes
        save()
        return true
    }
}

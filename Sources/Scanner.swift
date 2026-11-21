import Foundation
import Photos
import SwiftUI

@MainActor
final class Scanner: ObservableObject {
    enum Phase { case idle, scanning, done }

    @Published var auth: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var processed = 0
    @Published var total = 0
    @Published var skipped = 0
    @Published var stage = "Анализирую фото"
    @Published var lastError: String?
    @Published var liveFixes: [String: LiveFix] = [:]

    @Published var photos: [String: PhotoInfo] = [:]
    @Published var groups: [[String]] = []
    @Published var blurry: [String] = []
    @Published var badExposure: [String] = []
    @Published var badFaces: [String] = []
    @Published var screenshots: [String] = []

    private var infos: [PhotoInfo] = []
    private var task: Task<Void, Never>?

    var extraInGroups: Int { groups.reduce(0) { $0 + $1.count - 1 } }

    /// Живые фото, которые можно исправить, не предлагаем удалять
    func visible(_ ids: [String]) -> [String] { ids.filter { liveFixes[$0] == nil } }

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
        stage = "Анализирую фото"
        liveFixes = [:]

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let limit { opts.fetchLimit = limit }
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        total = assets.count

        var collected: [PhotoInfo] = []
        await withTaskGroup(of: PhotoInfo?.self) { group in
            var idx = 0
            let parallel = 4
            while idx < min(parallel, assets.count) {
                let a = assets[idx]; idx += 1
                group.addTask { await Analyzer.analyze(a) }
            }
            while let result = await group.next() {
                if let result { collected.append(result) } else { skipped += 1 }
                processed += 1
                progress = Double(processed) / Double(max(total, 1))
                if Task.isCancelled { group.cancelAll(); break }
                if idx < assets.count {
                    let a = assets[idx]; idx += 1
                    group.addTask { await Analyzer.analyze(a) }
                }
            }
        }

        infos = collected
        photos = Dictionary(uniqueKeysWithValues: collected.map { ($0.id, $0) })
        await reclassify()
        if !Task.isCancelled { await findLiveFixes() }
        phase = .done
    }

    /// Для неудачных живых фото ищем кадр лучше внутри видео
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

    func reclassify() async {
        let snapshot = infos
        let t = Thresholds.current
        let r = await Task.detached(priority: .userInitiated) {
            Classifier.classify(snapshot, t)
        }.value
        groups = r.groups
        blurry = r.blurry
        badExposure = r.badExposure
        badFaces = r.badFaces
        screenshots = r.screenshots
    }

    /// Удаляет фото (iOS сама спросит подтверждение). Попадают в "Недавно удалённые".
    @discardableResult
    func delete(_ ids: [String]) async -> Bool {
        let assets = ids.compactMap { photos[$0]?.asset }
        guard !assets.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            return false
        }
        let gone = Set(ids)
        infos.removeAll { gone.contains($0.id) }
        for id in ids { photos[id] = nil }
        groups = groups.map { $0.filter { !gone.contains($0) } }.filter { $0.count > 1 }
        blurry.removeAll { gone.contains($0) }
        badExposure.removeAll { gone.contains($0) }
        badFaces.removeAll { gone.contains($0) }
        screenshots.removeAll { gone.contains($0) }
        return true
    }
}

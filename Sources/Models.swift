import Foundation
import Photos
import Vision
import UIKit

/// Метрики качества кадра
struct Metrics: Codable {
    var sharpness: Double = 0        // резкость самого резкого участка (объекта)
    var globalSharpness: Double = 0  // резкость всего кадра
    var brightness: Double = 128     // средняя яркость 0...255
    var clipped: Double = 0          // доля почти чёрных/белых пикселей
    var faceQuality: Double? = nil   // лучшее качество лица 0...1 (nil — лиц нет)
}

/// То, что сохраняется между запусками, чтобы не анализировать фото заново
struct CacheEntry: Codable {
    var modified: Date?
    var bytes: Int64
    var metrics: Metrics
    var dHash: UInt64
    var featurePrint: Data?
}

/// Решения пользователя — живут между запусками
struct Decisions: Codable {
    var trash: Set<String> = []              // отложено на удаление
    var protected: Set<String> = []          // «не трогать»
    var preferred: Set<String> = []          // выбрано лучшим вручную
    var notDuplicatePairs: Set<String> = []  // «это не дубли»
    var swipeReviewed: Set<String> = []      // просмотрено в свайп-режиме
    var freedBytes: Int64 = 0                // сколько всего освобождено
}

/// Одно фото с результатами анализа
struct PhotoInfo: Identifiable, @unchecked Sendable {
    let id: String
    let asset: PHAsset
    let date: Date?
    let isScreenshot: Bool
    let isLive: Bool
    let isFavorite: Bool
    let isEdited: Bool
    let inAlbum: Bool
    let bytes: Int64
    let m: Metrics
    let dHash: UInt64
    let featurePrint: VNFeaturePrintObservation?

    /// Общая оценка: качество кадра + бонус за избранное и правки
    var score: Double {
        Analyzer.score(m) + (isFavorite ? 0.5 : 0) + (isEdited ? 0.2 : 0)
    }
}

/// Найденный в Live Photo кадр лучше текущего титульного
struct LiveFix: Identifiable, @unchecked Sendable {
    let id: String
    let time: Double        // секунда внутри видео Live Photo
    let preview: UIImage
    let oldScore: Double
    let newScore: Double
}

/// Пороги — настраиваются в приложении
struct Thresholds: Sendable {
    var similar: Double = 0.35   // расстояние "отпечатков": меньше = строже
    var blur: Double = 120       // резкость объекта ниже — размытое
    var dark: Double = 35        // средняя яркость ниже — тёмное
    var bright: Double = 225     // выше — пересвеченное
    var face: Double = 0.25      // качество лица ниже — плохое лицо

    static let defaults = Thresholds()

    static var current: Thresholds {
        let d = UserDefaults.standard
        func v(_ key: String, _ def: Double) -> Double { d.object(forKey: key) as? Double ?? def }
        return Thresholds(
            similar: v(Keys.similar, defaults.similar),
            blur: v(Keys.blur, defaults.blur),
            dark: v(Keys.dark, defaults.dark),
            bright: v(Keys.bright, defaults.bright),
            face: v(Keys.face, defaults.face)
        )
    }
}

enum Prefs {
    static var protectAlbums: Bool { UserDefaults.standard.object(forKey: Keys.protectAlbums) as? Bool ?? true }
    static var protectEdited: Bool { UserDefaults.standard.object(forKey: Keys.protectEdited) as? Bool ?? true }
}

enum Keys {
    static let similar = "t.similar"
    static let blur = "t.blur2"
    static let dark = "t.dark"
    static let bright = "t.bright"
    static let face = "t.face"
    static let scope = "scope"
    static let protectAlbums = "p.albums"
    static let protectEdited = "p.edited"
}

struct Results: Sendable {
    var groups: [[String]] = []
    var accidental: [String] = []
}

func pairKey(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// Сохранение на диск
enum Store {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var decisionsURL: URL { dir.appendingPathComponent("decisions.json") }
    static var cacheURL: URL { dir.appendingPathComponent("cache.plist") }

    static func loadDecisions() -> Decisions {
        guard let data = try? Data(contentsOf: decisionsURL),
              let d = try? JSONDecoder().decode(Decisions.self, from: data) else { return Decisions() }
        return d
    }

    static func save(_ d: Decisions) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: decisionsURL, options: .atomic) }
    }

    static func loadCache() -> [String: CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? PropertyListDecoder().decode([String: CacheEntry].self, from: data) else { return [:] }
        return c
    }

    static func saveCache(_ c: [String: CacheEntry]) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let data = try? enc.encode(c) { try? data.write(to: cacheURL, options: .atomic) }
    }

    static func clearCache() { try? FileManager.default.removeItem(at: cacheURL) }
}

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
    var text: String? = nil      // распознанный текст (только для скриншотов)
    var hasCode: Bool? = nil     // есть QR или штрихкод
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
    let text: String?
    let tags: [ScreenshotTag]

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

/// Что важного нашлось на скриншоте
enum ScreenshotTag: String, CaseIterable {
    case secret, document, money, ticket, address, contact, qr

    var emoji: String {
        switch self {
        case .secret: return "🔑"
        case .document: return "📄"
        case .money: return "💳"
        case .ticket: return "✈️"
        case .address: return "📍"
        case .contact: return "📞"
        case .qr: return "🔳"
        }
    }

    var label: String {
        switch self {
        case .secret: return "пароль / код"
        case .document: return "документ"
        case .money: return "деньги / банк"
        case .ticket: return "билет / бронь"
        case .address: return "адрес"
        case .contact: return "контакт"
        case .qr: return "QR / штрихкод"
        }
    }
}

/// Ищет в тексте скриншота важную информацию. Лучше лишний раз защитить, чем удалить нужное.
enum ScreenshotSorter {
    static let keywords: [ScreenshotTag: [String]] = [
        .secret: ["пароль", "password", "passcode", "логин", "login", "pin", "пин-код", "пин код",
                  "код подтверждения", "verification code", "one-time", "2fa", "otp", "seed",
                  "recovery phrase", "secret phrase", "мнемон", "private key", "приватный ключ",
                  "api key", "token", "mật khẩu", "wi-fi", "wifi", "ключ"],
        .document: ["паспорт", "passport", "виза", "visa", "снилс", "инн", "свидетельство", "договор",
                    "contract", "полис", "insurance policy", "водительск", "driver", "license", "лицензи",
                    "справк", "certificate", "id card", "căn cước", "hộ chiếu", "residence",
                    "tạm trú", "e-visa", "evisa", "документ", "document"],
        .money: ["перевод", "transfer", "чек", "receipt", "квитанц", "счёт", "счет", "invoice",
                 "оплат", "payment", "paid", "баланс", "balance", "iban", "swift", "бик",
                 "account number", "số tài khoản", "chuyển khoản", "usdt", "trc20", "erc20",
                 "₫", "vnd", "₽", "руб", "usd", "eur", "сбер", "тинькофф", "t-bank", "альфа",
                 "vietcombank", "techcombank", "momo", "binance", "bybit", "транзакц",
                 "transaction", "txid", "кошел", "wallet"],
        .ticket: ["билет", "ticket", "boarding", "посадочн", "рейс", "flight", "бронь", "booking",
                  "reservation", "бронирован", "check-in", "seat", "vé", "đặt phòng", "hotel",
                  "отель", "pnr", "gate"],
        .address: ["адрес", "address", "ул.", "улица", "street", "đường", "phường", "quận",
                   "district", "ward", "этаж", "apartment", "координат"]
    ]

    static let patterns: [(ScreenshotTag, String)] = [
        (.contact, "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"),
        (.contact, "\\+\\d[\\d\\s()-]{8,}\\d"),
        (.contact, "(?<!\\d)(?:0|8)\\d{9,10}(?!\\d)"),
        (.money, "(?:\\d[ -]?){16}"),
        (.money, "0x[a-fA-F0-9]{40}|T[1-9A-HJ-NP-Za-km-z]{33}|bc1[a-z0-9]{25,59}")
    ]

    static func tags(text: String, hasCode: Bool) -> [ScreenshotTag] {
        var found = Set<ScreenshotTag>()
        if hasCode { found.insert(.qr) }
        let lower = text.lowercased()
        for (tag, words) in keywords where words.contains(where: { has(lower, $0) }) {
            found.insert(tag)
        }
        let range = NSRange(text.startIndex..., in: text)
        for (tag, pattern) in patterns where !found.contains(tag) {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               re.firstMatch(in: text, options: [], range: range) != nil {
                found.insert(tag)
            }
        }
        return ScreenshotTag.allCases.filter { found.contains($0) }
    }

    /// Короткие латинские слова (pin, gate, seat…) ищем только целым словом,
    /// чтобы "shopping" или "navigate" не считались паролем или билетом
    static func has(_ lower: String, _ word: String) -> Bool {
        let shortLatin = word.count <= 5 && word.unicodeScalars.allSatisfy { $0.isASCII }
        guard shortLatin else { return lower.contains(word) }
        let pattern = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z0-9])"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    static func wordCount(_ text: String?) -> Int {
        (text ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

import Foundation
import Photos
import Vision
import UIKit

/// Результат анализа одного фото
struct PhotoInfo: Identifiable, @unchecked Sendable {
    let id: String
    let asset: PHAsset
    let date: Date?
    let isScreenshot: Bool
    let isLive: Bool

    var sharpness: Double = 0        // дисперсия Лапласиана: меньше = размытее
    var brightness: Double = 128     // средняя яркость 0...255
    var clipped: Double = 0          // доля почти чёрных/белых пикселей
    var faceQuality: Double? = nil   // лучшее качество лица 0...1 (nil — лиц нет)
    var dHash: UInt64 = 0
    var featurePrint: VNFeaturePrintObservation? = nil
    var score: Double = 0            // общая оценка кадра, для выбора лучшего в группе
}

/// Пороги — настраиваются в приложении
struct Thresholds: Sendable {
    var similar: Double = 0.35   // расстояние "отпечатков": меньше = строже
    var blur: Double = 100       // ниже — размытое
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

enum Keys {
    static let similar = "t.similar"
    static let blur = "t.blur"
    static let dark = "t.dark"
    static let bright = "t.bright"
    static let face = "t.face"
    static let scope = "scope"
}

struct Results: Sendable {
    var groups: [[String]] = []     // в каждой группе первый — лучший
    var blurry: [String] = []
    var badExposure: [String] = []
    var badFaces: [String] = []
    var screenshots: [String] = []
}

/// Метрики качества одного кадра
struct Metrics {
    var sharpness: Double = 0
    var brightness: Double = 128
    var clipped: Double = 0
    var faceQuality: Double? = nil
}

/// Найденный в Live Photo кадр лучше текущего титульного
struct LiveFix: Identifiable, @unchecked Sendable {
    let id: String
    let time: Double        // секунда внутри видео Live Photo
    let preview: UIImage
    let oldScore: Double
    let newScore: Double
}

import Foundation

struct ISSPass: Identifiable {
    let id = UUID()

    let start: Date
    let peak: Date
    let end: Date

    let maxElevation: Double    // degrees
    let startAzimuth: Double    // degrees
    let peakAzimuth: Double     // degrees
    let endAzimuth: Double      // degrees

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var timeUntilStart: TimeInterval { start.timeIntervalSinceNow }

    var quality: PassQuality {
        switch maxElevation {
        case 60...: return .excellent
        case 30..<60: return .good
        default:    return .fair
        }
    }

    func compassDirection(_ deg: Double) -> String {
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        let idx = Int((deg + 11.25) / 22.5) % 16
        return dirs[idx]
    }

    var startCompass: String  { compassDirection(startAzimuth) }
    var endCompass: String    { compassDirection(endAzimuth) }
}

enum PassQuality: String {
    case excellent = "Excellent"
    case good      = "Good"
    case fair      = "Fair"
}

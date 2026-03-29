import Foundation

struct TLEData: Codable {
    let name: String
    let line1: String
    let line2: String

    // wheretheiss.at /tles response keys
    enum CodingKeys: String, CodingKey {
        case name, line1, line2
    }
}

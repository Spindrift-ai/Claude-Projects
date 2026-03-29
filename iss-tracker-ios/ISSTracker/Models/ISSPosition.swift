import Foundation

struct ISSPosition: Decodable {
    let latitude: Double
    let longitude: Double
    let altitude: Double      // km
    let velocity: Double      // km/h
    let timestamp: TimeInterval

    // wheretheiss.at field names
    enum CodingKeys: String, CodingKey {
        case latitude, longitude, altitude, velocity, timestamp
    }
}

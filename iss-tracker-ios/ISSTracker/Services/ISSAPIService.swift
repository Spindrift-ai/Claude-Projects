import Foundation

enum ISSAPIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "Invalid API URL"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Decode error: \(e.localizedDescription)"
        case .noData:              return "No data received"
        }
    }
}

actor ISSAPIService {
    static let shared = ISSAPIService()
    private init() {}

    private let session = URLSession.shared
    private let positionURL = URL(string: "https://api.wheretheiss.at/v1/satellites/25544")!
    private let tleURL      = URL(string: "https://api.wheretheiss.at/v1/satellites/25544/tles")!

    // MARK: - Fetch current ISS position

    func fetchPosition() async throws -> ISSPosition {
        let (data, _) = try await session.data(from: positionURL)
        do {
            return try JSONDecoder().decode(ISSPosition.self, from: data)
        } catch {
            throw ISSAPIError.decodingError(error)
        }
    }

    // MARK: - Fetch TLE (Two-Line Element) data

    func fetchTLE() async throws -> TLEData {
        let (data, _) = try await session.data(from: tleURL)
        do {
            return try JSONDecoder().decode(TLEData.self, from: data)
        } catch {
            // wheretheiss.at TLE may return slightly different field casing — try manual parse
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let line1 = json["line1"] as? String,
               let line2 = json["line2"] as? String {
                return TLEData(name: json["name"] as? String ?? "ISS (ZARYA)", line1: line1, line2: line2)
            }
            throw ISSAPIError.decodingError(error)
        }
    }
}

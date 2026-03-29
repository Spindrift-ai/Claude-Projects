import Foundation
import CoreLocation
import Combine

@MainActor
final class ISSViewModel: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var issPosition: ISSPosition?
    @Published var userLocation: CLLocation?
    @Published var locationName: String = "Not set"
    @Published var upcomingPasses: [ISSPass] = []
    @Published var isComputingPasses = false
    @Published var notificationsEnabled = false
    @Published var statusMessage = "Fetching ISS position…"

    // MARK: - Private

    private var locationManager = CLLocationManager()
    private var updateTimer: Timer?
    private var tleCache: TLEData?
    private var tleFetchedAt: Date?
    private let tleTTL: TimeInterval = 3600   // 1 hour

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        startPositionUpdates()
        Task { await refreshNotificationStatus() }
    }

    // MARK: - ISS Live Position

    func startPositionUpdates() {
        Task { await fetchPosition() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchPosition() }
        }
    }

    private func fetchPosition() async {
        do {
            issPosition = try await ISSAPIService.shared.fetchPosition()
            if userLocation == nil {
                statusMessage = "Live · Set your location for pass alerts"
            }
        } catch {
            statusMessage = "Position unavailable – \(error.localizedDescription)"
        }
    }

    // MARK: - Location

    func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            statusMessage = "Location permission denied. Enter coordinates manually."
        }
    }

    /// Set a specific lat/lon (from manual entry or geolocation).
    func setLocation(lat: Double, lon: Double, altM: Double = 0) async {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altM,
            horizontalAccuracy: 1000,
            verticalAccuracy: -1,
            timestamp: Date()
        )
        userLocation = loc

        // Reverse-geocode for a human-readable name
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(loc),
           let place = placemarks.first {
            locationName = [place.locality, place.administrativeArea, place.country]
                .compactMap { $0 }
                .prefix(2)
                .joined(separator: ", ")
        } else {
            locationName = String(format: "%.2f°, %.2f°", lat, lon)
        }

        await computePasses()
    }

    // MARK: - Pass Computation

    func computePasses() async {
        guard let loc = userLocation else { return }
        isComputingPasses = true
        statusMessage = "Computing passes…"
        defer { isComputingPasses = false }

        do {
            let tle = try await fetchTLE()
            let lat = loc.coordinate.latitude
            let lon = loc.coordinate.longitude
            let alt = loc.altitude

            // Run CPU-heavy SGP4 loop off the main thread
            let passes = await Task.detached(priority: .userInitiated) {
                PassPredictor.computePasses(tle: tle, lat: lat, lon: lon, altM: max(alt, 0))
            }.value

            upcomingPasses = passes
            statusMessage = passes.isEmpty
                ? "No visible passes in the next 7 days"
                : "Next pass: \(timeUntilString(passes[0].start))"

            if notificationsEnabled {
                await NotificationManager.shared.scheduleNotifications(for: passes)
            }
        } catch {
            statusMessage = "Pass computation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - TLE Cache

    private func fetchTLE() async throws -> TLEData {
        if let cached = tleCache, let fetchedAt = tleFetchedAt,
           Date().timeIntervalSince(fetchedAt) < tleTTL {
            return cached
        }
        let tle = try await ISSAPIService.shared.fetchTLE()
        tleCache   = tle
        tleFetchedAt = Date()
        return tle
    }

    // MARK: - Notifications

    func refreshNotificationStatus() async {
        notificationsEnabled = await NotificationManager.shared.isAuthorized
    }

    func enableNotifications() async {
        let granted = await NotificationManager.shared.requestAuthorization()
        notificationsEnabled = granted
        if granted {
            await computePasses()
        }
    }

    func disableNotifications() {
        NotificationManager.shared.cancelAll()
        notificationsEnabled = false
    }

    // MARK: - Helpers

    func currentElevation() -> Double? {
        guard let loc = userLocation, let pos = issPosition else { return nil }
        // Quick great-circle approximation for display only
        let dlat = (pos.latitude - loc.coordinate.latitude) * .pi / 180
        let dlon = (pos.longitude - loc.coordinate.longitude) * .pi / 180
        let a = sin(dlat/2)*sin(dlat/2) +
                cos(loc.coordinate.latitude * .pi/180) *
                cos(pos.latitude * .pi/180) *
                sin(dlon/2)*sin(dlon/2)
        let groundDist = 2 * atan2(sqrt(a), sqrt(1-a)) * 6371   // km
        let altDiff    = pos.altitude - loc.altitude / 1000.0
        return atan2(altDiff, groundDist) * 180 / .pi
    }

    private func timeUntilString(_ date: Date) -> String {
        let sec = date.timeIntervalSinceNow
        if sec < 0      { return "now" }
        if sec < 3600   { return "\(Int(sec/60))m" }
        let h = Int(sec/3600); let m = Int(sec.truncatingRemainder(dividingBy: 3600)/60)
        return "\(h)h \(m)m"
    }
}

// MARK: - CLLocationManagerDelegate

extension ISSViewModel: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            await setLocation(lat: loc.coordinate.latitude,
                              lon: loc.coordinate.longitude,
                              altM: loc.altitude)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusMessage = "Location error: \(error.localizedDescription)"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }
}

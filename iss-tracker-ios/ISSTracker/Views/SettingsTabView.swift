import SwiftUI
import CoreLocation

struct SettingsTabView: View {
    @EnvironmentObject var vm: ISSViewModel

    @State private var latText  = ""
    @State private var lonText  = ""
    @State private var showManualEntry = false
    @State private var showLocationError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                locationSection
                notificationsSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .onAppear { prefillManualCoords() }
    }

    // MARK: - Location Section

    private var locationSection: some View {
        Section {
            // Current location display
            if let loc = vm.userLocation {
                HStack {
                    Label(vm.locationName, systemImage: "mappin.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.3f°, %.3f°",
                                loc.coordinate.latitude,
                                loc.coordinate.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Auto-detect
            Button {
                vm.requestLocation()
            } label: {
                Label("Use My Location", systemImage: "location.fill")
            }

            // Manual entry
            DisclosureGroup("Enter Coordinates Manually", isExpanded: $showManualEntry) {
                HStack {
                    Text("Latitude")
                        .frame(width: 80, alignment: .leading)
                    TextField("-90 to 90", text: $latText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Longitude")
                        .frame(width: 80, alignment: .leading)
                    TextField("-180 to 180", text: $lonText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Set Location") {
                    applyManualCoords()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manualCoordsValid)
            }

        } header: {
            Text("Location")
        } footer: {
            Text("Used to compute ISS passes overhead. Only stored on-device.")
                .font(.caption)
        }
        .alert("Invalid Coordinates", isPresented: $showLocationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        Section {
            HStack {
                Label("Pass Notifications", systemImage: "bell.fill")
                Spacer()
                if vm.notificationsEnabled {
                    Text("On")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                } else {
                    Text("Off")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            if vm.notificationsEnabled {
                alertRow("24 hours before pass", icon: "clock.badge")
                alertRow("1 hour before pass",   icon: "clock.badge")
                alertRow("5 minutes before pass", icon: "clock.badge.fill")

                Button(role: .destructive) {
                    vm.disableNotifications()
                } label: {
                    Label("Turn Off Notifications", systemImage: "bell.slash")
                }
            } else {
                Button {
                    Task { await vm.enableNotifications() }
                } label: {
                    Label("Enable Notifications", systemImage: "bell.badge")
                }
                .disabled(vm.userLocation == nil)
            }

        } header: {
            Text("Notifications")
        } footer: {
            if vm.userLocation == nil {
                Text("Set your location first to enable notifications.")
            } else if vm.notificationsEnabled {
                Text("Alerts will fire at 24 h, 1 h, and 5 min before each pass, even with the app closed.")
            }
        }
    }

    private func alertRow(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.green)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("ISS Catalog Number", value: "25544")
            LabeledContent("Orbit Data", value: "wheretheiss.at")
            LabeledContent("Propagator", value: "SGP4 (Vallado)")
            LabeledContent("Min Elevation", value: "10°")
            LabeledContent("Prediction Window", value: "7 days")
            LabeledContent("TLE Refresh", value: "Every hour")
        }
    }

    // MARK: - Helpers

    private func prefillManualCoords() {
        if let loc = vm.userLocation {
            latText = String(format: "%.4f", loc.coordinate.latitude)
            lonText = String(format: "%.4f", loc.coordinate.longitude)
        }
    }

    private var manualCoordsValid: Bool {
        guard let lat = Double(latText), let lon = Double(lonText) else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lon)
    }

    private func applyManualCoords() {
        guard let lat = Double(latText), let lon = Double(lonText) else {
            errorMessage = "Please enter valid decimal numbers."
            showLocationError = true
            return
        }
        guard (-90...90).contains(lat) else {
            errorMessage = "Latitude must be between -90 and 90."
            showLocationError = true
            return
        }
        guard (-180...180).contains(lon) else {
            errorMessage = "Longitude must be between -180 and 180."
            showLocationError = true
            return
        }
        Task { await vm.setLocation(lat: lat, lon: lon) }
        showManualEntry = false
    }
}

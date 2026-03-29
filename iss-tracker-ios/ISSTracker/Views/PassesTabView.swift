import SwiftUI

struct PassesTabView: View {
    @EnvironmentObject var vm: ISSViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.userLocation == nil {
                    ContentUnavailableView(
                        "No Location Set",
                        systemImage: "location.slash",
                        description: Text("Open Settings to set your location and see upcoming ISS passes.")
                    )
                } else if vm.isComputingPasses {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Computing passes…")
                            .foregroundStyle(.secondary)
                    }
                } else if vm.upcomingPasses.isEmpty {
                    ContentUnavailableView(
                        "No Visible Passes",
                        systemImage: "binoculars.fill",
                        description: Text("No ISS passes above 10° in the next 7 days for your location.")
                    )
                } else {
                    passList
                }
            }
            .navigationTitle("Upcoming Passes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.computePasses() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isComputingPasses || vm.userLocation == nil)
                }
            }
        }
    }

    private var passList: some View {
        List {
            notificationBanner

            ForEach(groupedPasses.keys.sorted(), id: \.self) { sectionTitle in
                Section(sectionTitle) {
                    ForEach(groupedPasses[sectionTitle] ?? []) { pass in
                        PassRowView(pass: pass)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var notificationBanner: some View {
        if !vm.notificationsEnabled {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Pass Notifications")
                            .font(.subheadline.weight(.semibold))
                        Text("Get alerts 24h, 1h, and 5 min before each pass.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Enable") {
                        Task { await vm.enableNotifications() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Group passes by day label ("Today", "Tomorrow", "Mon Mar 30", …)
    private var groupedPasses: [String: [ISSPass]] {
        let cal = Calendar.current
        var groups: [String: [ISSPass]] = [:]
        for pass in vm.upcomingPasses {
            let key: String
            if cal.isDateInToday(pass.start) {
                key = "Today"
            } else if cal.isDateInTomorrow(pass.start) {
                key = "Tomorrow"
            } else {
                key = pass.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            groups[key, default: []].append(pass)
        }
        return groups
    }
}

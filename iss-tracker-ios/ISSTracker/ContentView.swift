import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ISSViewModel()

    var body: some View {
        TabView {
            MapTabView()
                .tabItem {
                    Label("Live", systemImage: "globe")
                }

            PassesTabView()
                .tabItem {
                    Label("Passes", systemImage: "list.bullet.below.rectangle")
                }

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .environmentObject(vm)
        .task {
            // Refresh notification status each time the app comes to foreground
            await vm.refreshNotificationStatus()
        }
    }
}

#Preview {
    ContentView()
}

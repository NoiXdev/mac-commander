import SwiftUI

/// The Settings window (⌘,): General, Sidebar and Network tabs. Every control writes its store at once, so
/// open browser windows change live, and the stores persist to `UserDefaults`.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            SidebarSettings()
                .tabItem { Label(String(localized: "Sidebar"), systemImage: "sidebar.left") }
            NetworkSettings()
                .tabItem { Label(String(localized: "Network"), systemImage: "network") }
        }
        .frame(width: 520)
    }
}

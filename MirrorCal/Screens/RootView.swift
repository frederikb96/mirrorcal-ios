import SwiftUI

/// Three screens rather than one combined view, deliberately: status, configuration, and the log
/// are distinct concerns, and three separate tabs is also what makes the `Mac` workflow's
/// screenshot step able to assert "this is the log screen, not a blank one" per screen rather
/// than guessing at one long scroll.
struct RootView: View {
    @Environment(AppSyncEngine.self) private var engine

    #if DEBUG
        @Environment(AppScreenTracker.self) private var screenTracker
    #endif

    var body: some View {
        #if DEBUG
            TabView(
                selection: Binding(
                    get: { screenTracker.current },
                    set: { screenTracker.current = $0 }
                )
            ) {
                StatusView()
                    .tabItem { Label("Status", systemImage: "checkmark.circle") }
                    .tag(AppScreenTracker.Screen.status)
                ConfigurationView()
                    .tabItem { Label("Configuration", systemImage: "gearshape") }
                    .tag(AppScreenTracker.Screen.configuration)
                LogView()
                    .tabItem { Label("Log", systemImage: "doc.text") }
                    .tag(AppScreenTracker.Screen.log)
            }
        #else
            TabView {
                StatusView()
                    .tabItem { Label("Status", systemImage: "checkmark.circle") }
                ConfigurationView()
                    .tabItem { Label("Configuration", systemImage: "gearshape") }
                LogView()
                    .tabItem { Label("Log", systemImage: "doc.text") }
            }
        #endif
    }
}

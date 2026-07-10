import SwiftUI
import TennisCore

/// Three-tab shell: Home, Record, Profile (AC23).
struct TabShellView: View {
    let sessionStore: SessionStore

    var body: some View {
        TabView {
            HomePlaceholderView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            RecordPlaceholderView()
                .tabItem {
                    Label("Record", systemImage: "video")
                }

            ProfileView(sessionStore: sessionStore)
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
        }
    }
}

import SwiftUI
import TennisCore

/// Profile tab — provides a Logout button wired to SessionStore.logout() (AC23).
struct ProfileView: View {
    let sessionStore: SessionStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Log Out", role: .destructive) {
                        sessionStore.logout()
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

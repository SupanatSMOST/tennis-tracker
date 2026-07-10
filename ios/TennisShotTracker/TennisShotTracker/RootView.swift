import SwiftUI
import TennisCore

/// Routes the app between loading, auth, and the main tab shell based on
/// the session state observed from SessionStore (AC23).
struct RootView: View {
    let sessionStore: SessionStore
    let matchClient: MatchClient

    var body: some View {
        switch sessionStore.state {
        case .resolving:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unauthenticated:
            AuthView(sessionStore: sessionStore)

        case .authenticated:
            TabShellView(sessionStore: sessionStore, matchClient: matchClient)
        }
    }
}

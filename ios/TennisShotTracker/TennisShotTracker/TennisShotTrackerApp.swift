import SwiftUI
import TennisCore

@main
struct TennisShotTrackerApp: App {

    @State private var sessionStore: SessionStore
    private let matchClient: MatchClient

    init() {
        // Read TENNIS_API_BASE_URL from Info.plist; fall back to APIConfig default
        // (the default literal lives only in APIConfig — not here, AC19).
        let config: APIConfig
        if let raw = Bundle.main.object(forInfoDictionaryKey: "TENNIS_API_BASE_URL") as? String,
           let url = URL(string: raw) {
            config = APIConfig(baseURL: url)
        } else {
            config = APIConfig()
        }

        let tokenStore = KeychainTokenStore()
        let transport = URLSessionTransport()
        let client = APIClient(config: config, transport: transport, tokenStore: tokenStore)
        _sessionStore = State(initialValue: SessionStore(client: client, tokenStore: tokenStore))

        // MatchClient shares the same APIConfig / URLSessionTransport / KeychainTokenStore
        // so all requests go to the same backend with the same auth token (AC31 — no new dep).
        matchClient = MatchClient(config: config, transport: transport, tokenStore: tokenStore)
    }

    var body: some Scene {
        WindowGroup {
            RootView(sessionStore: sessionStore, matchClient: matchClient)
                .task {
                    await sessionStore.resolve()
                }
        }
    }
}

import SwiftUI
import TennisCore

/// Three-tab shell: Home (match list), Record (create/session flow), Profile (AC23/AC29).
struct TabShellView: View {
    let sessionStore: SessionStore
    let matchClient: MatchClient

    var body: some View {
        TabView {
            MatchListView(matchClient: matchClient)
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            CreateMatchEntryView(matchClient: matchClient)
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

/// Thin entry point for the Record tab — presents CreateMatchSheet directly
/// and routes into RecordSessionView on creation. Shares the same
/// MatchListViewModel create path as the Home tab (ponytail:no parallel impl).
private struct CreateMatchEntryView: View {
    let matchClient: MatchClient
    @State private var viewModel: MatchListViewModel
    @State private var path: [Route] = []
    @State private var showCreate = false

    init(matchClient: MatchClient) {
        self.matchClient = matchClient
        _viewModel = State(initialValue: MatchListViewModel(client: matchClient))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Button("New Match") {
                showCreate = true
            }
            .font(.headline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Record")
            .sheet(isPresented: $showCreate) {
                CreateMatchSheet(viewModel: viewModel)
            }
            .onChange(of: viewModel.createdMatch?.id) { _, newID in
                if let id = newID {
                    showCreate = false
                    path.append(.session(id))
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let matchID):
                    RecordSessionView(matchClient: matchClient, matchID: matchID, path: $path)
                case .summary(let matchID):
                    MatchSummaryView(matchClient: matchClient, matchID: matchID)
                }
            }
        }
    }
}

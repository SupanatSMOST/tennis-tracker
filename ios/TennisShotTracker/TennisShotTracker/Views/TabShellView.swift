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
/// and routes through the camera setup flow on creation (FR-V5). Shares the same
/// MatchListViewModel create path as the Home tab (ponytail:no parallel impl).
private struct CreateMatchEntryView: View {
    let matchClient: MatchClient
    @State private var viewModel: MatchListViewModel
    @State private var path: [Route] = []
    @State private var showCreate = false
    /// The single shared CameraSessionViewModel for the created-match flow (FR-V5 / D-1).
    /// Constructed once on creation; nil between navigations — mirrors MatchListView.
    @State private var cameraVM: CameraSessionViewModel?

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
                    // Newly created match is active — route through camera setup (FR-V5).
                    cameraVM = CameraSessionViewModel(camera: CameraService())
                    path.append(.cameraSetup(id))
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .cameraSetup(let matchID):
                    if let cam = cameraVM {
                        CameraSetupView(cameraVM: cam, matchID: matchID, path: $path)
                    }
                case .cornerTap(let matchID):
                    if let cam = cameraVM {
                        CornerTapView(cameraVM: cam, matchID: matchID, path: $path)
                    }
                case .session(let matchID):
                    RecordSessionView(matchClient: matchClient, matchID: matchID, path: $path, cameraVM: cameraVM)
                case .summary(let matchID):
                    MatchSummaryView(matchClient: matchClient, matchID: matchID)
                }
            }
        }
    }
}

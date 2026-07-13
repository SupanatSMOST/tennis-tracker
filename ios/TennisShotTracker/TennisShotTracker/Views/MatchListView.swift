import Foundation
import SwiftUI
import TennisCore

/// Home tab — shows all matches, most-recent-first. Toolbar "+" presents CreateMatchSheet.
/// Tapping a match routes by isActive: active → CameraSetupView → CornerTapView → RecordSessionView,
/// ended → MatchSummaryView. No networking, decoding, or zone-mapping logic (AC30).
///
/// Phase-2 routing (FR-V5 / D-1 / AC27):
/// - Active match tap: constructs ONE `CameraSessionViewModel`, stores it in `@State cameraVM`,
///   then pushes `.cameraSetup(id)` — the same VM instance flows through `.cornerTap` and
///   `.session` destinations via the navigationDestination switch.
/// - Ended match tap: `.summary` path is unchanged (AC27).
struct MatchListView: View {
    let matchClient: MatchClient
    @State private var viewModel: MatchListViewModel
    @State private var path: [Route] = []
    @State private var showCreate = false
    /// The single shared CameraSessionViewModel for the current active-match flow (FR-V5 / D-1).
    /// Constructed once on active-match entry; nil between navigations (AC27).
    @State private var cameraVM: CameraSessionViewModel?

    init(matchClient: MatchClient) {
        self.matchClient = matchClient
        _viewModel = State(initialValue: MatchListViewModel(client: matchClient))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if viewModel.matches.isEmpty && viewModel.loadError == nil {
                    ContentUnavailableView("No Matches", systemImage: "tennisball")
                } else {
                    List {
                        if let error = viewModel.loadError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        ForEach(viewModel.matches, id: \.id) { match in
                            Button {
                                if viewModel.isActive(match) {
                                    // Active match: construct the shared VM and enter
                                    // the camera setup flow (Phase 2, FR-V5).
                                    cameraVM = CameraSessionViewModel(camera: CameraService())
                                    path.append(.cameraSetup(match.id))
                                } else {
                                    // Ended match: summary path unchanged (AC27).
                                    path.append(.summary(match.id))
                                }
                            } label: {
                                MatchRowView(match: match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Matches")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
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
            .task {
                await viewModel.load()
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
                    // cameraVM may be nil if the user reaches .session via a
                    // direct deep-link or future code path — the optional default
                    // in RecordSessionView handles that gracefully (AC26).
                    RecordSessionView(matchClient: matchClient, matchID: matchID, path: $path, cameraVM: cameraVM)
                case .summary(let matchID):
                    // Ended-match path: unchanged (AC27).
                    MatchSummaryView(matchClient: matchClient, matchID: matchID)
                }
            }
        }
    }
}

// MARK: - Route

enum Route: Hashable {
    /// Phase 2: live preview + framing guide before corner taps.
    case cameraSetup(String)
    /// Phase 2: sequential 4-corner tap to calibrate court homography.
    case cornerTap(String)
    /// Active recording session (manual zone-tap grid).
    case session(String)
    /// Post-match summary for ended matches (AC27: unchanged).
    case summary(String)
}

// MARK: - Match row

private struct MatchRowView: View {
    let match: MatchResponse

    var body: some View {
        HStack {
            Text(match.courtSurface.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(surfaceColor(match.courtSurface).opacity(0.2))
                .foregroundStyle(surfaceColor(match.courtSurface))
                .clipShape(Capsule())

            Spacer()

            Text(formattedDate(match.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if match.endedAt == nil {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    /// Display-only date formatting from the opaque ISO createdAt string.
    /// ponytail: two-pass parse (with/without fractional seconds) because the
    /// backend timestamp format is not pinned in spec (A-7 — opaque String).
    /// Upgrade path: pin a single format when the backend contract is locked.
    private func formattedDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return raw
    }

    private func surfaceColor(_ surface: String) -> Color {
        switch surface {
        case "clay":  return .orange
        case "grass": return .green
        default:      return .blue    // hard
        }
    }
}

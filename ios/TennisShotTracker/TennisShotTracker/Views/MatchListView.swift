import Foundation
import SwiftUI
import TennisCore

/// Home tab — shows all matches, most-recent-first. Toolbar "+" presents CreateMatchSheet.
/// Tapping a match routes by isActive: active → RecordSessionView, ended → MatchSummaryView.
/// No networking, decoding, or zone-mapping logic (AC30).
struct MatchListView: View {
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
                                let route: Route = viewModel.isActive(match)
                                    ? .session(match.id)
                                    : .summary(match.id)
                                path.append(route)
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
                    path.append(.session(id))
                }
            }
            .task {
                await viewModel.load()
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

// MARK: - Route

enum Route: Hashable {
    case session(String)
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

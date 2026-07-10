import SwiftUI
import TennisCore

/// Summary screen — shows per-zone shot counts as a bar list.
/// All data comes from MatchSummaryViewModel.entries (AC30).
struct MatchSummaryView: View {
    let matchClient: MatchClient
    let matchID: String

    @State private var viewModel: MatchSummaryViewModel

    init(matchClient: MatchClient, matchID: String) {
        self.matchClient = matchClient
        self.matchID = matchID
        _viewModel = State(initialValue: MatchSummaryViewModel(client: matchClient, matchID: matchID))
    }

    var body: some View {
        Group {
            if let error = viewModel.loadError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.bar")
            } else {
                summaryGrid
            }
        }
        .navigationTitle("Match Summary")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
    }

    private var summaryGrid: some View {
        let maxCount = viewModel.entries.map(\.count).max() ?? 1
        return List {
            ForEach(viewModel.entries, id: \.zone) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.zone.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline)
                        Spacer()
                        Text("\(entry.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        let fillWidth = maxCount > 0
                            ? geo.size.width * CGFloat(entry.count) / CGFloat(maxCount)
                            : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(fillWidth, 4), height: 8)
                    }
                    .frame(height: 8)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

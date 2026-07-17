import SwiftUI
import TennisCore

/// CV shot review screen — lists detected bounces and lets the user
/// submit or discard them.
///
/// Zone badges are cosmetic only; per-zone color is defined locally here
/// (AC28 — no logic, purely presentational). No existing views in the app
/// target define a zone→Color mapping, so a simple per-zone lookup is fine.
///
/// No CV/coordinate/networking logic lives here — all via the VM (AC28).
struct CVShotReviewView: View {
    let matchClient: MatchClient
    let matchID: String
    let shots: [CVShotResult]

    @State private var vm: PostProcessingViewModel

    init(
        vm: PostProcessingViewModel,
        matchClient: MatchClient,
        matchID: String,
        shots: [CVShotResult]
    ) {
        self.matchClient = matchClient
        self.matchID = matchID
        self.shots = shots
        _vm = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(shots.enumerated()), id: \.offset) { index, shot in
                    HStack(spacing: 10) {
                        // Frame number
                        Text("Frame \(shot.frameIndex)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)

                        Spacer()

                        // Zone name
                        Text(shot.zone.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline)

                        // Zone colour badge (cosmetic — AC28)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(zoneColor(shot.zone))
                            .frame(width: 12, height: 12)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)

            Divider()

            // Action buttons
            HStack(spacing: 16) {
                // Discard → vm.dismiss() → .idle (AC22).
                Button("Discard", role: .destructive) {
                    vm.dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                // Submit N → vm.submit → addShots with source:"cv" (AC19/OQ-5).
                Button("Submit \(shots.count) shot\(shots.count == 1 ? "" : "s")") {
                    Task {
                        await vm.submit(matchId: matchID, matchClient: matchClient)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(shots.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Review Shots")
        .navigationBarTitleDisplayMode(.inline)
        // Show any submit-failure message inline.
        .overlay(alignment: .bottom) {
            if case .failed(let message) = vm.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal)
                    .padding(.bottom, 80) // clear the action bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: vm.state == .idle)
    }

    // MARK: - Zone colour (cosmetic — stays in the view per spec, AC28)

    /// Returns a distinct colour per zone for the badge. These are purely
    /// decorative; ZoneClassifier owns the classification logic (AC28).
    private func zoneColor(_ zone: String) -> Color {
        switch zone {
        case "front_court_left":  return .green
        case "front_court_right": return .mint
        case "baseline_left":     return .blue
        case "baseline_right":    return .indigo
        case "out_left":          return .orange
        case "out_right":         return .red
        default:                  return .gray
        }
    }
}

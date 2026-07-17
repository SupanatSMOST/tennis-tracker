import SwiftUI
import TennisCore

/// Post-processing screen — drives the CV pipeline and routes to review.
///
/// Observes `PostProcessingViewModel` state machine:
///   .idle          → spinner placeholder (immediately transitions on appear)
///   .processing    → ProgressView + note + Cancel
///   .done(shots)   → CVShotReviewView inline
///   .failed(msg)   → error message + Retry
///
/// No CV/coordinate/networking logic lives here — all via the VM (AC28).
struct PostProcessingView: View {
    let matchClient: MatchClient
    let matchID: String

    @State private var vm: PostProcessingViewModel

    init(vm: PostProcessingViewModel, matchClient: MatchClient, matchID: String) {
        self.matchClient = matchClient
        self.matchID = matchID
        _vm = State(initialValue: vm)
    }

    var body: some View {
        Group {
            switch vm.state {
            case .idle:
                // Transient — startProcessing on appear moves us off this quickly.
                ProgressView()

            case .processing(let progress):
                processingContent(progress: progress)

            case .done(let shots):
                CVShotReviewView(
                    vm: vm,
                    matchClient: matchClient,
                    matchID: matchID,
                    shots: shots
                )

            case .failed(let message):
                failedContent(message: message)
            }
        }
        .navigationTitle("Analysing Video")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // .task attaches to the outer container so startProcessing runs once,
            // not re-fired when state changes swap the inner content (AC27).
            await vm.startProcessing(matchId: matchID, matchClient: matchClient)
        }
    }

    // MARK: - Sub-views

    private func processingContent(progress: Double) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Progress bar bound to the .processing(progress) value (AC27).
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)

                Text("\(Int(progress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("This may take a few minutes")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Cancel affordance — calls vm.dismiss() → .idle (AC22).
            Button("Cancel", role: .cancel) {
                vm.dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Retry re-runs startProcessing from .idle.
            Button("Retry") {
                Task {
                    await vm.startProcessing(matchId: matchID, matchClient: matchClient)
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }
}

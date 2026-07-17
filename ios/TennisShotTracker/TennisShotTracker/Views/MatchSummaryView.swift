import SwiftUI
import TennisCore

/// Summary screen — shows per-zone shot counts as a bar list.
/// All data comes from MatchSummaryViewModel.entries (AC30).
///
/// This view is also the CV **composition root** (plan §3.4): when both a
/// recorded video and a court calibration exist for the match, an
/// "Analyse Video" toolbar button is shown.  Tapping it constructs the concrete
/// CVPipeline (FrameExtractor + BallTrackerInference + BounceDetectorInference,
/// all #if !os(macOS)-guarded) together with a PostProcessingViewModel and
/// presents PostProcessingView as a sheet.
///
/// No CV / coordinate / networking logic lives here — all via the VM (AC28).
struct MatchSummaryView: View {
    let matchClient: MatchClient
    let matchID: String

    @State private var viewModel: MatchSummaryViewModel

    // MARK: - CV composition root state

    /// True when both video and calibration are present on disk for this match.
    /// Evaluated once on appear; drives the "Analyse Video" button visibility (AC26 / A-9).
    @State private var canAnalyse: Bool = false

    /// Non-nil while the CV post-processing sheet is presented.
    /// Built fresh on each tap so a stale VM is never reused.
    @State private var postProcessingVM: PostProcessingViewModel? = nil

    /// Drives the sheet. True when postProcessingVM is set; cleared when the sheet
    /// is dismissed (which sets postProcessingVM back to nil via onDisappear).
    @State private var showingPostProcessing: Bool = false

    /// Error shown when the CoreML model files are absent at tap time.
    @State private var modelLoadError: String? = nil

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
        .toolbar {
            // "Analyse Video" is visible/enabled ONLY when both video and
            // calibration exist on disk for this match (AC26 / A-9).
            if canAnalyse {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startAnalysis()
                    } label: {
                        Label("Analyse Video", systemImage: "waveform.path.ecg")
                    }
                }
            }
        }
        .task {
            await viewModel.load()
            evaluateCanAnalyse()
        }
        // Sheet: presented when a PostProcessingViewModel has been built.
        // The sheet destination is wrapped in #if !os(macOS) because
        // PostProcessingView uses the #if-guarded concrete pipeline types at
        // composition time; MatchSummaryView is app-target (iOS) only so this
        // guard is for belt-and-suspenders correctness.
#if !os(macOS)
        .sheet(isPresented: $showingPostProcessing, onDismiss: {
            // Discard the VM when the sheet closes so the next tap always gets
            // a fresh pipeline (no stale state from a prior analysis run).
            postProcessingVM = nil
        }) {
            if let vm = postProcessingVM {
                NavigationStack {
                    PostProcessingView(vm: vm, matchClient: matchClient, matchID: matchID)
                }
            }
        }
#endif
        .alert("Model Not Installed", isPresented: Binding(
            get: { modelLoadError != nil },
            set: { if !$0 { modelLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { modelLoadError = nil }
        } message: {
            Text(modelLoadError ?? "")
        }
    }

    // MARK: - Summary grid (unchanged from Phase 2)

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

    // MARK: - Composition root helpers (AC28 — no CV/coordinate/networking logic here)

    /// Constructs the concrete CVPipeline and presents the post-processing sheet.
    ///
    /// Uses `try` per coordination note 1 — force-try would crash if the model
    /// files are absent; a thrown error surfaces as a user-visible alert instead.
    ///
    /// The #if !os(macOS) guard is required because FrameExtractor /
    /// BallTrackerInference / BounceDetectorInference only exist in the iOS build.
    private func startAnalysis() {
#if !os(macOS)
        do {
            let ballTracker = try BallTrackerInference()
            let bounceDetector = try BounceDetectorInference()
            let pipeline = CVPipeline(
                frameExtractor: FrameExtractor(),
                ballTracker: ballTracker,
                bounceDetector: bounceDetector
            )
            postProcessingVM = PostProcessingViewModel(pipeline: pipeline)
            showingPostProcessing = true
        } catch {
            // Model files absent — surface a clear error rather than crashing
            // (coordination note 1 / plan §3.4 model-loading posture).
            // ponytail: replace with a dedicated "model not installed" onboarding
            // screen in v2 when model files are distributed with the app.
            modelLoadError = error.localizedDescription
        }
#endif
    }

    /// Checks disk for both the video and calibration files (AC26 / A-9).
    /// Called from `.task` so it runs once after the view appears.
    private func evaluateCanAnalyse() {
        let videoStore = LocalVideoStore()
        let calibrationStore = CalibrationStore()
        canAnalyse = videoStore.exists(for: matchID) && calibrationStore.exists(for: matchID)
    }
}

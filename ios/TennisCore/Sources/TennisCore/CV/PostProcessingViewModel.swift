/// PostProcessingViewModel — @Observable VM for the CV post-processing screen.
///
/// State machine:
///   .idle  →  startProcessing  →  .processing(0.0)  →  ... →  .done(shots)
///                                                           ↘  .failed(message)
///   .done  →  submit           →  (stays .done on success; .failed on transport error)
///   any    →  dismiss          →  .idle
///
/// AC21 retry: a failed submit retains `detectedShots` so the caller can invoke
/// `submit` again (from `.done`) without re-running the pipeline.
///
/// AC23: missing video or missing calibration → `.failed` immediately; the
/// pipeline is never invoked.

import Foundation
import Observation

// MARK: - ProcessingState

/// The possible states of `PostProcessingViewModel`.
///
/// No `.cancelled` case — cancellation is `dismiss()` → `.idle` (AC22).
public enum ProcessingState: Equatable {
    case idle
    case processing(progress: Double)
    case done(shots: [CVShotResult])
    case failed(message: String)
}

// MARK: - PostProcessingViewModel

@Observable
public final class PostProcessingViewModel {

    // MARK: - State

    /// Current processing state. Starts at `.idle` (AC16).
    public private(set) var state: ProcessingState = .idle

    // MARK: - Dependencies

    private let pipeline: CVProcessing
    private let videoStore: LocalVideoStore
    private let calibrationStore: CalibrationStore

    // MARK: - Private retained shots (AC21 retry)

    /// Held across a failed submit so the user can retry without re-running the
    /// pipeline.  Set on `.done`; cleared on `.idle` via `dismiss()`.
    private var detectedShots: [CVShotResult] = []

    // MARK: - Init

    /// - Parameters:
    ///   - pipeline: The CV pipeline implementation; injected for testing (use
    ///     `MockCVPipeline` in tests).
    ///   - videoStore: Override for AC23 temp-dir isolation; defaults to the
    ///     production `Documents`-backed store.
    ///   - calibrationStore: Override for AC23 temp-dir isolation; defaults to
    ///     the production `Documents`-backed store.
    public init(
        pipeline: CVProcessing,
        videoStore: LocalVideoStore = LocalVideoStore(),
        calibrationStore: CalibrationStore = CalibrationStore()
    ) {
        self.pipeline = pipeline
        self.videoStore = videoStore
        self.calibrationStore = calibrationStore
    }

    // MARK: - Actions

    /// Runs the CV pipeline over the recorded video for `matchId`.
    ///
    /// Guard: if the video is absent **or** the calibration is missing, sets
    /// `.failed(message:)` immediately and does NOT run the pipeline (AC23).
    ///
    /// On success: `state` transitions `.idle → .processing(0.0) → .done(shots)`.
    /// On pipeline error: `state = .failed(message:)` (AC18) — never crashes,
    /// never emits `.done` on a throw.
    ///
    /// - Parameters:
    ///   - matchId: The match whose local video + calibration files are used.
    ///   - matchClient: Provided here for API symmetry with `submit`; unused in
    ///     this method.
    ///     ponytail: parameter kept per pinned signature (plan §3.2.8 / Task 10
    ///     view layer passes matchClient to both methods uniformly); upgrade path
    ///     is to remove it only if the view contract is redesigned.
    public func startProcessing(matchId: String, matchClient: MatchClient) async {
        // AC23: guard — video must exist on disk
        guard videoStore.exists(for: matchId) else {
            state = .failed(message: "No recorded video found for this match.")
            return
        }

        // AC23: guard — calibration must have been saved
        guard let calibration = calibrationStore.load(for: matchId) else {
            state = .failed(message: "No court calibration found for this match.")
            return
        }

        let videoURL = videoStore.videoURL(for: matchId)

        // AC17: enter processing state before the async call
        state = .processing(progress: 0.0)

        do {
            let shots = try await pipeline.process(
                videoURL: videoURL,
                calibration: calibration,
                progress: { [weak self] p in
                    // AC13: relay pipeline progress into state
                    self?.state = .processing(progress: p)

                }
            )
            // AC17: success → .done; retain shots for AC21
            detectedShots = shots
            state = .done(shots: shots)
        } catch {
            // AC18: any throw → .failed; never .done, never crash
            state = .failed(message: errorMessage(error))
        }
    }

    /// Submits the detected shots to the server.
    ///
    /// Only operates when `state` is `.done(shots:)`.  If the VM is in `.failed`
    /// and `detectedShots` is non-empty (i.e. a previous submit failed) the state
    /// is first restored to `.done` so the same shots can be re-submitted without
    /// re-running the pipeline (AC21).
    ///
    /// Every shot is submitted with `source: "cv"` (AC19 — never "manual").
    /// On transport failure: `state = .failed(message:)` and `detectedShots` is
    /// preserved so another `submit` call can retry (AC21).
    ///
    /// - Parameters:
    ///   - matchId: The match to which the shots are attached.
    ///   - matchClient: The API client used to post the shots.
    public func submit(matchId: String, matchClient: MatchClient) async {
        // AC21: if a prior submit failed but shots are retained, re-enter .done
        if case .failed = state, !detectedShots.isEmpty {
            state = .done(shots: detectedShots)
        }

        guard case .done(let shots) = state else { return }

        do {
            // AC19: every source MUST be "cv" — ShotInput default is "manual",
            // so we pass the label explicitly on every element.
            _ = try await matchClient.addShots(
                matchID: matchId,
                shots: shots.map { ShotInput(zone: $0.zone, source: "cv") }
            )
            // Success: stay in .done so the view can navigate away naturally.
            // No invented .submitted case (pinned enum; YAGNI).
        } catch {
            // AC21: transport failure → .failed, BUT retain detectedShots for retry
            state = .failed(message: errorMessage(error))
        }
    }

    /// Resets state to `.idle`, discarding any partial or completed results.
    ///
    /// This is also the cancel affordance — the view calls `dismiss()` when the
    /// user taps Cancel (no `.cancelled` case needed; AC22).
    public func dismiss() {
        detectedShots = []
        state = .idle
    }

    // MARK: - Private

    private func errorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError, let msg = apiError.backendMessage {
            return msg
        }
        return error.localizedDescription
    }
}

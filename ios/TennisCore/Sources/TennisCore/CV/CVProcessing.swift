/// CVProcessing — the single VM-facing seam for the on-device CV pipeline.
///
/// `CourtCalibration` is defined in `Calibration/CalibrationStore.swift` (same
/// module); no extra import is needed beyond `Foundation`.
///
/// The `progress` closure is non-`@Sendable` and invoked inline — the pipeline
/// drives it synchronously within the `async` call, not across an actor hop
/// (plan §3.2.2).  `PostProcessingViewModel` passes a closure that updates its
/// `state` on the caller's context.
///
/// Failure always surfaces by throwing — partial results are never returned
/// (AC8).

import Foundation

// MARK: - CVPipelineError

/// Pipeline-internal errors for the CV processing path.
///
/// Cases are consumed by `CVPipeline` (Task 5).
// ponytail: only two cases defined — `invalidCalibration` and `processingFailed`.
// No further taxonomy until Task 5 shows what the concrete pipeline actually
// needs.  Upgrade path: add cases in CVPipeline.swift or here as Tasks 5–9
// reveal new failure modes.
public enum CVPipelineError: Error, Equatable {

    /// The supplied `CourtCalibration` is malformed (e.g. homographyMatrix
    /// does not have exactly 9 elements).
    case invalidCalibration(String)

    /// A pipeline stage failed for a described reason.
    case processingFailed(String)
}

// MARK: - CVProcessing

/// The single seam between `PostProcessingViewModel` and the CV pipeline.
///
/// Concrete implementations:
/// - `MockCVPipeline` (Sources — shippable stub for tests + SwiftUI previews)
/// - `CVPipeline` (Sources — orchestrates `FrameExtracting`, `BallTracking`,
///   `BounceDetecting`; Task 5)
/// - CoreML-backed workers are `#if !os(macOS)`-guarded (Tasks 7–9)
public protocol CVProcessing {

    /// Runs the full pipeline over the video, mapping bounces to zoned shots.
    ///
    /// - Parameters:
    ///   - videoURL: Local URL of the recorded `.mov` file.
    ///   - calibration: The court homography produced by the Phase-2 4-corner
    ///     tap calibration step.
    ///   - progress: Called with a monotonically non-decreasing value in
    ///     `[0, 1]` as the pipeline advances (AC13).  Invoked inline (not
    ///     across an actor boundary); callers must not block inside it.
    /// - Returns: One `CVShotResult` per detected bounce that had a localized
    ///   ball point, in bounce-frame order (AC14).
    /// - Throws: `CVPipelineError` or any error propagated from the underlying
    ///   ML inference stages.
    func process(
        videoURL: URL,
        calibration: CourtCalibration,
        progress: @escaping (Double) -> Void
    ) async throws -> [CVShotResult]
}

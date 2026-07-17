/// MockCVPipeline — shippable in-Sources stub for `CVProcessing`.
///
/// Lives in `Sources/TennisCore/CV/`, NOT in `Tests/`, so that it is
/// available to `PostProcessingViewModel` tests AND to SwiftUI previews
/// (mirrors the `MockCameraService` pattern in `Camera/MockCameraService.swift`).
///
/// Compile target: all platforms (macOS + iOS), so `swift test` on macOS can
/// instantiate it directly (hermetic gate, plan §2 / AC24).
///
/// Usage:
/// ```swift
/// let mock = MockCVPipeline()
/// mock.stubbedResults = [CVShotResult(frameIndex: 3, zone: "baseline_left", ...)]
/// let shots = try await mock.process(videoURL: url, calibration: cal) { _ in }
/// // shots == mock.stubbedResults
/// ```

import Foundation

/// A fully configurable in-memory stub for `CVProcessing`.
///
/// **Behaviour:**
/// - If `stubbedError` is non-nil, `process(...)` throws it immediately (AC8).
/// - Otherwise `process(...)` calls `progress(0.0)`, then `progress(1.0)`, and
///   returns `stubbedResults` in the order they were set (AC6 / AC7).
public final class MockCVPipeline: CVProcessing {

    // MARK: - Configuration

    /// Results returned by `process(...)` when no error is configured.
    /// Defaults to `[]` (AC6 — empty returns no shots and does not throw).
    public var stubbedResults: [CVShotResult] = []

    /// When non-nil, `process(...)` throws this error instead of returning
    /// results (AC8).
    public var stubbedError: Error?

    // MARK: - Init

    public init() {}

    // MARK: - CVProcessing

    /// Simulates a pipeline run.
    ///
    /// - If `stubbedError != nil`: throws it.
    /// - Otherwise: calls `progress(0.0)`, then `progress(1.0)`, and returns
    ///   `stubbedResults` in order.
    public func process(
        videoURL: URL,
        calibration: CourtCalibration,
        progress: @escaping (Double) -> Void
    ) async throws -> [CVShotResult] {
        if let error = stubbedError {
            throw error
        }
        progress(0.0)
        progress(1.0)
        return stubbedResults
    }
}

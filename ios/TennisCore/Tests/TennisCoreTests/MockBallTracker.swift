/// MockBallTracker — test double for `BallTracking` (Task 4).
///
/// Lives in `Tests/TennisCoreTests/` — consumed by `CVPipelineTests` (Task 5).
/// `import CoreVideo` is required because the protocol method accepts
/// `[CVPixelBuffer]`, even though the stub ignores the argument.
///
/// Usage:
/// ```swift
/// let mock = MockBallTracker()
/// mock.stubbedPoints = [(x: 640, y: 360), nil, (x: 200, y: 100)]
/// let points = try await mock.track(frames: pixelBuffers)
/// // points == mock.stubbedPoints
/// ```

import CoreVideo
import XCTest
@testable import TennisCore

/// A configurable stub for `BallTracking` that returns a caller-set point
/// sequence regardless of the `frames` argument.
final class MockBallTracker: BallTracking {

    /// The per-frame ball points returned by `track(frames:)`.
    /// Elements may be nil to simulate "no ball detected" (AC11).
    var stubbedPoints: [(x: Float, y: Float)?] = []

    func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?] {
        return stubbedPoints
    }
}

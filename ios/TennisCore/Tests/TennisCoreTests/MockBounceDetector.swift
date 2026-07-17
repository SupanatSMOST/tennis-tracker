/// MockBounceDetector — test double for `BounceDetecting` (Task 4).
///
/// Lives in `Tests/TennisCoreTests/` — consumed by `CVPipelineTests` (Task 5).
/// No CoreVideo dependency (the protocol has no CVPixelBuffer in its signature).
///
/// Usage:
/// ```swift
/// let mock = MockBounceDetector()
/// mock.stubbedBounceIndices = [2, 5, 8]
/// let indices = try await mock.detectBounces(ballPoints: trajectory)
/// // indices == Set([2, 5, 8])
/// ```

import XCTest
@testable import TennisCore

/// A configurable stub for `BounceDetecting` that returns a caller-set set of
/// bounce frame indices regardless of the `ballPoints` argument.
final class MockBounceDetector: BounceDetecting {

    /// The bounce frame indices returned by `detectBounces(ballPoints:)`.
    var stubbedBounceIndices: Set<Int> = []

    func detectBounces(
        ballPoints: [(index: Int, point: (x: Float, y: Float)?)]
    ) async throws -> Set<Int> {
        return stubbedBounceIndices
    }
}

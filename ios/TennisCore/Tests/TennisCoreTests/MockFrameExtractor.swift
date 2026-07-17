/// MockFrameExtractor — test double for `FrameExtracting` (Task 4).
///
/// Lives in `Tests/TennisCoreTests/` (not `Sources/`) — only needed by
/// `CVPipelineTests` (Task 5).  `CVPixelBuffer` is CoreVideo and compiles on
/// macOS, so no `#if` guard is required.
///
/// Usage:
/// ```swift
/// let mock = MockFrameExtractor()
/// mock.stubbedFrames = [(index: 0, pixelBuffer: buf0), (index: 1, pixelBuffer: buf1)]
/// let frames = try await mock.extractFrames(from: url, every: 1)
/// // frames == mock.stubbedFrames
/// ```

import CoreVideo
import XCTest
@testable import TennisCore

/// A configurable stub for `FrameExtracting` that returns a caller-set frame
/// sequence regardless of the `url` and `stride` arguments.
final class MockFrameExtractor: FrameExtracting {

    /// The frames returned by `extractFrames(from:every:)`.
    var stubbedFrames: [(index: Int, pixelBuffer: CVPixelBuffer)] = []

    func extractFrames(
        from url: URL,
        every stride: Int
    ) async throws -> [(index: Int, pixelBuffer: CVPixelBuffer)] {
        return stubbedFrames
    }
}

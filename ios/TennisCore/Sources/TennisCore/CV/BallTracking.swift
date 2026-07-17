/// BallTracking — protocol for the ball-detection stage of the CV pipeline.
///
/// Concrete implementation (`BallTrackerInference`) is CoreML-backed and
/// `#if !os(macOS)`-guarded (Task 8 — build-only).  The protocol itself
/// compiles on macOS via CoreVideo.
///
/// Output coordinate space (OQ-1 RESOLVED): landscape `1280×720` pixel space.
/// `CVPipeline` normalises each point to fractions before applying the
/// homography (`fx = px/1280`, `fy = py/720` — plan §5.2).

import CoreVideo

/// Detects ball positions in a sequence of pixel buffers.
public protocol BallTracking {

    /// Returns one optional ball point per input frame, in the same order as
    /// `frames`.
    ///
    /// - Parameter frames: The pixel buffers to analyse, in sequence order.
    /// - Returns: An array whose length equals `frames.count`.  Each element
    ///   is `nil` when no ball was detected in the corresponding frame (AC11),
    ///   or an `(x, y)` tuple in landscape `1280×720` pixel space (§5.1).
    /// - Throws: Any CoreML inference or model-loading error.
    func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?]
}

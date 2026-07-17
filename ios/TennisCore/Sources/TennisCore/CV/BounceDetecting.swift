/// BounceDetecting — protocol for the bounce-detection stage of the CV pipeline.
///
/// Concrete implementation (`BounceDetectorInference`) is CoreML-backed and
/// `#if !os(macOS)`-guarded (Task 9 — build-only).  This protocol has no
/// CoreVideo or CoreML dependency; all types are stdlib/standard.
///
/// The input is the **indexed ball trajectory** (not raw pixel buffers) because
/// the CatBoost bounce model operates on trajectory features, not pixels
/// (plan §3.2.6 note).  `CVPipeline` runs `BallTracking` first, then hands
/// the resulting indexed trajectory to this detector.
///
/// `index` values match the ORIGINAL-video frame numbers produced by
/// `FrameExtracting` (A-6), so the returned `Set<Int>` is directly comparable
/// to those indices.

/// Detects bounces from an indexed ball trajectory.
public protocol BounceDetecting {

    /// Identifies frames at which a ball bounce occurred.
    ///
    /// - Parameter ballPoints: The per-frame ball trajectory, where each element
    ///   is the ORIGINAL-video frame `index` paired with an optional `(x, y)`
    ///   ball position (nil when no ball was detected in that frame).  The
    ///   CatBoost features derive from this trajectory, not from raw pixels.
    /// - Returns: The set of ORIGINAL-video frame indices at which a bounce was
    ///   detected.  An empty set means no bounces → no shots (AC12).
    /// - Throws: Any CoreML inference or model-loading error.
    func detectBounces(
        ballPoints: [(index: Int, point: (x: Float, y: Float)?)]
    ) async throws -> Set<Int>
}

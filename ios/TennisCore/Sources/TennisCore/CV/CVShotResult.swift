/// CVShotResult — value type produced by the CV pipeline for each detected bounce.
///
/// Imports only `Foundation` so this type compiles on macOS under `swift test`
/// with no CoreML or AVFoundation present (hermetic gate, plan §2 / AC24).
///
/// Field semantics:
/// - `frameIndex`: the ORIGINAL-video frame number at which the bounce was detected
///   (stride applied — A-6).  Not the position in the result array.
/// - `zone`: one of the six §3.1 zone strings produced by `ZoneClassifier`.
/// - `normalizedCourtX` / `normalizedCourtY`: the homography-projected court
///   coordinate in `[0,1]×[0,1]` space (plan §5.2 Step 2).
/// - `ballPixelX` / `ballPixelY`: the raw ball centroid in landscape `1280×720`
///   pixel space (OQ-1 RESOLVED).

import Foundation

public struct CVShotResult: Equatable {

    /// The ORIGINAL-video frame number (stride applied — A-6).
    public let frameIndex: Int

    /// One of the six §3.1 zone strings (front_court_left, front_court_right,
    /// baseline_left, baseline_right, out_left, out_right).
    public let zone: String

    /// Homography-projected court X in [0, 1] (plan §5.2 Step 2 courtX).
    public let normalizedCourtX: Float

    /// Homography-projected court Y in [0, 1] (plan §5.2 Step 2 courtY).
    public let normalizedCourtY: Float

    /// Raw ball centroid X in landscape 1280×720 pixel space (OQ-1).
    public let ballPixelX: Float

    /// Raw ball centroid Y in landscape 1280×720 pixel space (OQ-1).
    public let ballPixelY: Float

    // Explicit public init — synthesized memberwise init is `internal` for a
    // `public` struct (mirrors `CGPointCodable` in CalibrationStore.swift).
    public init(
        frameIndex: Int,
        zone: String,
        normalizedCourtX: Float,
        normalizedCourtY: Float,
        ballPixelX: Float,
        ballPixelY: Float
    ) {
        self.frameIndex = frameIndex
        self.zone = zone
        self.normalizedCourtX = normalizedCourtX
        self.normalizedCourtY = normalizedCourtY
        self.ballPixelX = ballPixelX
        self.ballPixelY = ballPixelY
    }
}

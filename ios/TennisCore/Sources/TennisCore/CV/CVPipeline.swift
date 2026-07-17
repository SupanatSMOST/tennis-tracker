/// CVPipeline — concrete `CVProcessing` implementation; the coordinate-chain crown jewel.
///
/// Orchestrates the three worker protocols (`FrameExtracting`, `BallTracking`,
/// `BounceDetecting`) and applies the **row-major homography array formula
/// verbatim** (plan §5.2) to convert each bounce ball-pixel to a court point
/// and zone.
///
/// CRITICAL — the row-major indexing contract (plan §5.2 / AC15):
///   `calibration.homographyMatrix` is a 9-element ROW-MAJOR `[Float]` stored
///   as `[m00,m01,m02, m10,m11,m12, m20,m21,m22]` (`m[3*r + c]`).
///   This class applies the formula *directly* on the array — it does NOT
///   reconstruct a `simd_float3x3` and does NOT call `HomographyService`.
///   Reconstructing a simd column-major matrix from the row-major array would
///   silently transpose the homography, producing shape-valid but wrong zones
///   (the AC15 transpose-guard test catches exactly this).
///
/// Imports:
///   - `Foundation` — `URL`, standard library
///   - `CoreGraphics` — `CGPoint`, `CGRect` for `ZoneClassifier`
///   No CoreML, AVFoundation, or simd import — this file compiles on macOS
///   under `swift test` with no model files present (hermetic gate AC24).

import Foundation
import CoreGraphics

// MARK: - CVPipeline

/// Concrete `CVProcessing` that runs the full on-device bounce-to-zone pipeline.
public final class CVPipeline: CVProcessing {

    // MARK: Stored properties

    private let frameExtractor: FrameExtracting
    private let ballTracker: BallTracking
    private let bounceDetector: BounceDetecting

    /// Number of video frames to skip between each extracted frame.
    /// Default 1 = every frame (OQ-3 LOCKED).
    private let stride: Int

    // MARK: Init

    /// - Parameters:
    ///   - frameExtractor: Extracts pixel buffers from the video file.
    ///   - ballTracker: Detects ball position per frame (returns nil when absent).
    ///   - bounceDetector: Identifies bounce frame indices from the trajectory.
    ///   - stride: Frame stride passed to `frameExtractor`. Default 1 (OQ-3).
    public init(
        frameExtractor: FrameExtracting,
        ballTracker: BallTracking,
        bounceDetector: BounceDetecting,
        stride: Int = 1
    ) {
        self.frameExtractor = frameExtractor
        self.ballTracker = ballTracker
        self.bounceDetector = bounceDetector
        self.stride = stride
    }

    // MARK: CVProcessing

    /// Runs the full pipeline: extract frames → track ball → detect bounces →
    /// apply coordinate chain → classify zone → emit results.
    ///
    /// Progress milestones (monotonic, all in [0, 1]):
    ///   0.0  — start
    ///   0.33 — frame extraction complete
    ///   0.66 — ball tracking complete
    ///   0.90 — bounce detection complete
    ///   1.0  — done
    ///
    /// - Returns: One `CVShotResult` per bounce frame that has a non-nil ball
    ///   point, in ascending bounce-frame-index order (AC14).  Returns `[]`
    ///   when the bounce set is empty (AC12).
    public func process(
        videoURL: URL,
        calibration: CourtCalibration,
        progress: @escaping (Double) -> Void
    ) async throws -> [CVShotResult] {

        // Step 1 — start
        progress(0.0)

        // Step 2 — extract frames
        let frames = try await frameExtractor.extractFrames(from: videoURL, every: stride)
        progress(0.33)

        // Step 3 — track ball positions (index-aligned to frames by array position)
        let balls = try await ballTracker.track(frames: frames.map(\.pixelBuffer))
        progress(0.66)

        // Step 4 — build indexed trajectory and detect bounces
        // `balls` is position-aligned to `frames`; `frames[i].index` is the
        // ORIGINAL-video frame number (A-6), which may differ from `i` when
        // stride > 1.  Never index into `balls` via `frame.index`.
        let trajectory: [(index: Int, point: (x: Float, y: Float)?)] =
            frames.indices.map { i in
                (index: frames[i].index, point: balls[i])
            }
        let bounceSet = try await bounceDetector.detectBounces(ballPoints: trajectory)
        progress(0.90)

        // Step 5 — coordinate chain + zone classification
        // Iterate frames in ascending order (FrameExtracting contract → ascending
        // index) so the result array is in bounce-frame order (AC14).
        // Convert homographyMatrix from [Float] to [Double] once for arithmetic
        // precision; px/py stay Float for the result fields.
        let mf = calibration.homographyMatrix        // [Float], 9 elements, ROW-MAJOR
        let m: [Double] = mf.map(Double.init)        // promote once for chain precision

        var results: [CVShotResult] = []

        for i in frames.indices {
            let frameIndex = frames[i].index

            // Skip frames that are not bounce frames (AC12 / AC14)
            guard bounceSet.contains(frameIndex) else { continue }

            // Skip bounces with no detected ball (AC11)
            guard let ball = balls[i] else { continue }

            let px = ball.x   // Float — preserved verbatim for ballPixelX/Y fields
            let py = ball.y

            // §5.2 Step 1 — pixel → image-fraction (landscape 1280×720, OQ-1 LOCKED)
            let fx: Double = Double(px) / 1280.0
            let fy: Double = Double(py) / 720.0

            // §5.2 Step 2 — ROW-MAJOR homography application (m[3*r + c])
            // DO NOT reconstruct a simd_float3x3 — that would require column-major
            // init and silently re-transpose the matrix (AC15 transpose guard).
            // DO NOT call HomographyService — same risk via H*columnVector.
            let xp: Double = m[0] * fx + m[1] * fy + m[2]   // row 0
            let yp: Double = m[3] * fx + m[4] * fy + m[5]   // row 1
            let w:  Double = m[6] * fx + m[7] * fy + m[8]   // row 2

            let courtX: Double = xp / w
            let courtY: Double = yp / w

            // §5.2 Step 3 — court point → zone via the shared classifier
            let zone = ZoneClassifier.classify(
                point: CGPoint(x: courtX, y: courtY),
                in: CGRect(x: 0, y: 0, width: 1, height: 1)
            )

            results.append(CVShotResult(
                frameIndex: frameIndex,
                zone: zone,
                normalizedCourtX: Float(courtX),
                normalizedCourtY: Float(courtY),
                ballPixelX: px,
                ballPixelY: py
            ))
        }

        // Step 6 — done
        progress(1.0)

        return results
    }
}

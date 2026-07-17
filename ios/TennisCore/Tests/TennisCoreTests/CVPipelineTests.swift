/// CVPipelineTests — coordinate-chain and transpose-guard tests (Task 5, AC9–AC15).
///
/// The asymmetric fraction-space image quad (plan §5.4):
///   imagePoints = [(0.1,0.1),(0.9,0.15),(0.05,0.9),(0.95,0.85)]  [TL,TR,BL,BR]
///   courtPoints = [(0,0),(1,0),(0,1),(1,1)]                         unit square
///
/// H is built once at suite start via HomographyService.compute and stored in
/// `calibration`.  Six ball pixels are derived at runtime via H.inverse so the
/// round-trip is always self-consistent (plan §5.4 mandate: fraction space).
///
/// Test count: 6 (AC9) + 1 (AC10) + 1 (AC11) + 1 (AC12) + 1 (AC13) +
///             1 (AC14) + 1 (AC15) = 12 total.  Suite goes 122 → 134.

import XCTest
import CoreGraphics
import simd
import CoreVideo
@testable import TennisCore

// MARK: - CVPipelineTests

final class CVPipelineTests: XCTestCase {

    // MARK: Shared fixture state

    /// Asymmetric fraction-space image quad (§5.4 mandate).
    private let imageQuad: [CGPoint] = [
        CGPoint(x: 0.10, y: 0.10),   // TL
        CGPoint(x: 0.90, y: 0.15),   // TR
        CGPoint(x: 0.05, y: 0.90),   // BL
        CGPoint(x: 0.95, y: 0.85),   // BR
    ]

    /// Unit-square court points [TL,TR,BL,BR].
    private let courtQuad: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1),
        CGPoint(x: 1, y: 1),
    ]

    /// Computed once in `setUp`; used by all tests.
    private var H: simd_float3x3!
    private var calibration: CourtCalibration!

    /// Convenience: a dummy pixel buffer (content irrelevant — mock ignores it).
    private var dummyBuffer: CVPixelBuffer!

    override func setUp() {
        super.setUp()

        // Build the homography from the fraction-space quad.
        guard let h = HomographyService.compute(imagePoints: imageQuad, courtPoints: courtQuad) else {
            XCTFail("HomographyService.compute returned nil for the fraction-space quad — degenerate quad?")
            return
        }
        H = h

        // Build CourtCalibration via the shared conversion seam.
        let ipCodable = imageQuad.map { CGPointCodable(x: $0.x, y: $0.y) }
        let cpCodable = courtQuad.map { CGPointCodable(x: $0.x, y: $0.y) }
        calibration = CourtCalibration(
            matchId: "test-pipeline",
            imagePoints: ipCodable,
            courtPoints: cpCodable,
            homography: H
        )

        // Create a tiny 2×2 pixel buffer (contents irrelevant — mocks ignore them).
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
        dummyBuffer = pb!
    }

    // MARK: - Helpers

    /// Returns the ball pixel (px, py) in 1280×720 that the pipeline would map
    /// to the given court point `(cx, cy)` via the current fixture homography.
    ///
    /// Derivation: px/1280 = fx, py/720 = fy, and (fx,fy) = H.inverse * (cx,cy,1).
    private func ballPixel(forCourtX cx: Float, courtY cy: Float) -> (px: Float, py: Float) {
        let frac = H.inverse * SIMD3<Float>(cx, cy, 1)
        let fx = frac.x / frac.z
        let fy = frac.y / frac.z
        return (px: fx * 1280.0, py: fy * 720.0)
    }

    /// Applies the row-major homography chain (§5.2) to a pixel and returns
    /// (courtX, courtY) using Double precision — mirrors the pipeline exactly.
    private func rowMajorChain(px: Float, py: Float) -> (courtX: Double, courtY: Double) {
        let m = calibration.homographyMatrix.map(Double.init)
        let fx = Double(px) / 1280.0
        let fy = Double(py) / 720.0
        let xp = m[0] * fx + m[1] * fy + m[2]
        let yp = m[3] * fx + m[4] * fy + m[5]
        let w  = m[6] * fx + m[7] * fy + m[8]
        return (xp / w, yp / w)
    }

    /// Applies the COLUMN-MAJOR (transposed) chain — used only in the AC15 guard.
    private func columnMajorChain(px: Float, py: Float) -> (courtX: Double, courtY: Double) {
        let m = calibration.homographyMatrix.map(Double.init)
        let fx = Double(px) / 1280.0
        let fy = Double(py) / 720.0
        // Transposed indexing: x'=m0·fx+m3·fy+m6, y'=m1·fx+m4·fy+m7, w=m2·fx+m5·fy+m8
        let xp = m[0] * fx + m[3] * fy + m[6]
        let yp = m[1] * fx + m[4] * fy + m[7]
        let w  = m[2] * fx + m[5] * fy + m[8]
        return (xp / w, yp / w)
    }

    /// Classifies a (courtX, courtY) point in [0,1]×[0,1].
    private func classify(courtX: Double, courtY: Double) -> String {
        ZoneClassifier.classify(
            point: CGPoint(x: courtX, y: courtY),
            in: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    /// Builds a minimal CVPipeline wired to the given mocks.
    private func makePipeline(
        extractor: MockFrameExtractor,
        tracker: MockBallTracker,
        bounceDetector: MockBounceDetector
    ) -> CVPipeline {
        CVPipeline(
            frameExtractor: extractor,
            ballTracker: tracker,
            bounceDetector: bounceDetector
        )
    }

    // MARK: - AC9: six zone classification tests (one per zone)

    /// front_court_left: target court point (0.25, 0.17) — left column, near-net row.
    func testAC9_zone_frontCourtLeft() async throws {
        let (px, py) = ballPixel(forCourtX: 0.25, courtY: 0.17)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "front_court_left",
                       "ball pixel (\(px),\(py)) should map to front_court_left")
    }

    /// front_court_right: target court point (0.75, 0.17) — right column, near-net row.
    func testAC9_zone_frontCourtRight() async throws {
        let (px, py) = ballPixel(forCourtX: 0.75, courtY: 0.17)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "front_court_right",
                       "ball pixel (\(px),\(py)) should map to front_court_right")
    }

    /// baseline_left: target court point (0.25, 0.50) — left column, mid row.
    func testAC9_zone_baselineLeft() async throws {
        let (px, py) = ballPixel(forCourtX: 0.25, courtY: 0.50)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "baseline_left",
                       "ball pixel (\(px),\(py)) should map to baseline_left")
    }

    /// baseline_right: target court point (0.75, 0.50) — right column, mid row.
    func testAC9_zone_baselineRight() async throws {
        let (px, py) = ballPixel(forCourtX: 0.75, courtY: 0.50)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "baseline_right",
                       "ball pixel (\(px),\(py)) should map to baseline_right")
    }

    /// out_left: target court point (0.25, 0.83) — left column, deep row.
    func testAC9_zone_outLeft() async throws {
        let (px, py) = ballPixel(forCourtX: 0.25, courtY: 0.83)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "out_left",
                       "ball pixel (\(px),\(py)) should map to out_left")
    }

    /// out_right: target court point (0.75, 0.83) — right column, deep row.
    func testAC9_zone_outRight() async throws {
        let (px, py) = ballPixel(forCourtX: 0.75, courtY: 0.83)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(videoURL: URL(fileURLWithPath: "/dev/null"), calibration: calibration, progress: { _ in })

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].zone, "out_right",
                       "ball pixel (\(px),\(py)) should map to out_right")
    }

    // MARK: - AC10: ballPixelX/Y and normalizedCourtX/Y fields are correct

    /// Verifies that all six CVShotResult values carry the correct pixel and
    /// court-coordinate fields.  The expected court coords are recomputed in
    /// the test via the row-major chain (not via the inverse fixture) so this
    /// does not trivially tautologise AC9.
    func testAC10_resultFieldsMatchInputAndRowMajorChain() async throws {
        // Use all six zone targets in one batch so AC10 covers the full matrix.
        let targets: [(cx: Float, cy: Float, zone: String)] = [
            (0.25, 0.17, "front_court_left"),
            (0.75, 0.17, "front_court_right"),
            (0.25, 0.50, "baseline_left"),
            (0.75, 0.50, "baseline_right"),
            (0.25, 0.83, "out_left"),
            (0.75, 0.83, "out_right"),
        ]

        var frames: [(index: Int, pixelBuffer: CVPixelBuffer)] = []
        var points: [(x: Float, y: Float)?] = []
        var bounceIndices: Set<Int> = []

        for (i, t) in targets.enumerated() {
            let (px, py) = ballPixel(forCourtX: t.cx, courtY: t.cy)
            frames.append((index: i, pixelBuffer: dummyBuffer))
            points.append((x: px, y: py))
            bounceIndices.insert(i)
        }

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = frames

        let tracker = MockBallTracker()
        tracker.stubbedPoints = points

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = bounceIndices

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { _ in }
        )

        XCTAssertEqual(results.count, 6)

        // Results are in ascending frame-index order (AC14), matching `targets` order.
        for (i, t) in targets.enumerated() {
            let r = results[i]
            let (px, py) = ballPixel(forCourtX: t.cx, courtY: t.cy)

            // ballPixelX/Y must equal the input pixel exactly.
            XCTAssertEqual(r.ballPixelX, px, accuracy: 1e-3,
                           "frame \(i): ballPixelX \(r.ballPixelX) ≠ input \(px)")
            XCTAssertEqual(r.ballPixelY, py, accuracy: 1e-3,
                           "frame \(i): ballPixelY \(r.ballPixelY) ≠ input \(py)")

            // normalizedCourtX/Y must match the row-major chain recomputed in test.
            let (expectedCX, expectedCY) = rowMajorChain(px: px, py: py)
            XCTAssertEqual(Double(r.normalizedCourtX), expectedCX, accuracy: 1e-4,
                           "frame \(i): normalizedCourtX \(r.normalizedCourtX) ≠ expected \(expectedCX)")
            XCTAssertEqual(Double(r.normalizedCourtY), expectedCY, accuracy: 1e-4,
                           "frame \(i): normalizedCourtY \(r.normalizedCourtY) ≠ expected \(expectedCY)")

            XCTAssertEqual(r.zone, t.zone, "frame \(i): zone mismatch")
        }
    }

    // MARK: - AC11: nil-ball bounce is skipped

    /// Bounce set {5,9}; frame 5's ball is nil → only frame 9 produces a result.
    func testAC11_nilBallBounceIsSkipped() async throws {
        let (px, py) = ballPixel(forCourtX: 0.75, courtY: 0.50)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [
            (index: 5, pixelBuffer: dummyBuffer),
            (index: 9, pixelBuffer: dummyBuffer),
        ]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [
            nil,                    // frame 5 — no ball
            (x: px, y: py),         // frame 9 — ball present
        ]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [5, 9]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { _ in }
        )

        XCTAssertEqual(results.count, 1,
                       "expected 1 result (nil-ball bounce skipped); got \(results.count)")
        XCTAssertEqual(results[0].frameIndex, 9)
    }

    // MARK: - AC12: empty bounce set produces no results

    /// MockBounceDetector returns [] → process returns [] even with non-nil balls.
    func testAC12_emptyBounceSetProducesNoResults() async throws {
        let (px, py) = ballPixel(forCourtX: 0.25, courtY: 0.50)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [
            (index: 0, pixelBuffer: dummyBuffer),
            (index: 1, pixelBuffer: dummyBuffer),
        ]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [
            (x: px, y: py),
            (x: px, y: py),
        ]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = []   // no bounces

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { _ in }
        )

        XCTAssertEqual(results.count, 0,
                       "empty bounce set must yield [], got \(results.count) results")
    }

    // MARK: - AC13: progress is monotonic, in [0,1], ≥1 call, final == 1.0

    func testAC13_progressIsMonotonicAndEndsAtOne() async throws {
        let (px, py) = ballPixel(forCourtX: 0.25, courtY: 0.17)

        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 0, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: px, y: py)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [0]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)

        var progressValues: [Double] = []
        _ = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { v in progressValues.append(v) }
        )

        XCTAssertGreaterThanOrEqual(progressValues.count, 1,
                                    "progress callback must be called at least once")

        // All values in [0,1]
        for v in progressValues {
            XCTAssertGreaterThanOrEqual(v, 0.0, "progress \(v) is below 0.0")
            XCTAssertLessThanOrEqual(v, 1.0, "progress \(v) exceeds 1.0")
        }

        // Non-decreasing
        for i in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(
                progressValues[i], progressValues[i - 1],
                "progress decreased from \(progressValues[i-1]) to \(progressValues[i]) at index \(i)"
            )
        }

        // Final value must be 1.0
        XCTAssertEqual(progressValues.last, 1.0,
                       "final progress must be 1.0, got \(progressValues.last!)")
    }

    // MARK: - AC14: one result per (bounce frame, non-nil ball), in bounce-frame order

    /// Frames [0..4]; bounceSet {1,3}; ball nil at 1, non-nil at 3 → 1 result, frameIndex 3.
    /// A second run uses bounceSet {0,2,4} with non-nil balls → 3 results in ascending order.
    func testAC14_resultsAreInBounceFrameOrderAndCountMatchesNonNilBalls() async throws {
        let (px, py) = ballPixel(forCourtX: 0.75, courtY: 0.17)

        let frameCount = 5
        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = (0..<frameCount).map { i in
            (index: i, pixelBuffer: dummyBuffer)
        }

        let tracker = MockBallTracker()
        // frames 0,2,4 → non-nil ball; frames 1,3 → nil ball
        tracker.stubbedPoints = [
            (x: px, y: py),   // frame 0
            nil,               // frame 1
            (x: px, y: py),   // frame 2
            nil,               // frame 3
            (x: px, y: py),   // frame 4
        ]

        let bounceDetector = MockBounceDetector()
        // bounceSet intersects non-nil balls at {0,2,4}
        bounceDetector.stubbedBounceIndices = [0, 2, 4]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { _ in }
        )

        XCTAssertEqual(results.count, 3,
                       "expected 3 results for bounceSet={0,2,4} with non-nil balls; got \(results.count)")

        // Frame indices must be in ascending order.
        let frameIndices = results.map(\.frameIndex)
        XCTAssertEqual(frameIndices, [0, 2, 4],
                       "results must be in ascending bounce-frame order; got \(frameIndices)")
    }

    // MARK: - AC15: transpose guard (DEDICATED test — load-bearing)

    /// Pins a ball pixel chosen so that the row-major (correct) and column-major
    /// (transposed) chains classify it into DIFFERENT zones.
    ///
    /// We verify divergence inside the test (XCTAssertNotEqual on the two
    /// computed zones) so no offline arithmetic is trusted blindly.
    ///
    /// Target pixel chosen deliberately to be near zone boundaries where
    /// transposing H's off-diagonal elements causes maximum drift.
    /// Court target: (0.48, 0.48) — near the intersection of x=0.5 and y=1/3.
    /// Row-major → left/baseline area; transposed chain may produce a different zone.
    func testAC15_transposedHomographyClassifiesIntoDifferentZone() async throws {
        // We search for a pixel that actually diverges between row-major and
        // column-major chains using the asymmetric fixture H.
        //
        // Strategy: scan a grid of court-space targets and find the first one
        // whose row-major and column-major zones differ.  Assert the pipeline
        // outputs the row-major zone.

        var foundDivergence = false
        var chosenPx: Float = 0
        var chosenPy: Float = 0
        var rowMajorZone = ""
        var transposedZone = ""

        // Scan near boundaries of zones (x around 0.5, y around 1/3 and 2/3)
        // where an asymmetric H would create the most drift when transposed.
        let candidates: [(cx: Float, cy: Float)] = [
            (0.48, 0.30), (0.52, 0.30), (0.48, 0.36), (0.52, 0.36),
            (0.48, 0.62), (0.52, 0.62), (0.48, 0.68), (0.52, 0.68),
            (0.30, 0.30), (0.70, 0.30), (0.30, 0.65), (0.70, 0.65),
            (0.45, 0.45), (0.55, 0.45), (0.45, 0.55), (0.55, 0.55),
        ]

        for c in candidates {
            let (px, py) = ballPixel(forCourtX: c.cx, courtY: c.cy)
            let (rmCX, rmCY) = rowMajorChain(px: px, py: py)
            let (cmCX, cmCY) = columnMajorChain(px: px, py: py)
            let rmZone = classify(courtX: rmCX, courtY: rmCY)
            let cmZone = classify(courtX: cmCX, courtY: cmCY)
            if rmZone != cmZone {
                foundDivergence = true
                chosenPx = px
                chosenPy = py
                rowMajorZone = rmZone
                transposedZone = cmZone
                break
            }
        }

        // The asymmetric quad guarantees a diverging pixel exists.
        // If this fails, the quad is accidentally symmetric — a fixture bug.
        XCTAssertTrue(foundDivergence,
                      "Could not find a pixel where row-major and column-major chains diverge — " +
                      "the fixture quad may be accidentally symmetric. " +
                      "This means AC15 cannot be verified.")

        // Now run the pipeline with the diverging pixel.
        let extractor = MockFrameExtractor()
        extractor.stubbedFrames = [(index: 42, pixelBuffer: dummyBuffer)]

        let tracker = MockBallTracker()
        tracker.stubbedPoints = [(x: chosenPx, y: chosenPy)]

        let bounceDetector = MockBounceDetector()
        bounceDetector.stubbedBounceIndices = [42]

        let pipeline = makePipeline(extractor: extractor, tracker: tracker, bounceDetector: bounceDetector)
        let results = try await pipeline.process(
            videoURL: URL(fileURLWithPath: "/dev/null"),
            calibration: calibration,
            progress: { _ in }
        )

        XCTAssertEqual(results.count, 1)

        // Self-verification: the two chains produce different zones.
        XCTAssertNotEqual(rowMajorZone, transposedZone,
                          "The two chains must diverge for AC15 to be meaningful. " +
                          "Row-major: \(rowMajorZone), transposed: \(transposedZone)")

        // The pipeline must use the correct ROW-MAJOR zone.
        XCTAssertEqual(results[0].zone, rowMajorZone,
                       "Pipeline produced zone '\(results[0].zone)' but row-major expected " +
                       "'\(rowMajorZone)' (transposed would give '\(transposedZone)'). " +
                       "Ball pixel: (\(chosenPx), \(chosenPy))")
    }
}

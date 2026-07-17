import XCTest
import CoreGraphics
import simd
@testable import TennisCore

final class HomographyServiceTests: XCTestCase {

    // MARK: - Shared helper

    /// Applies H to a point using the pinned Phase-3 convention: H * columnVector,
    /// then normalizes by the homogeneous coordinate (p.z).
    private func apply(_ H: simd_float3x3, to point: CGPoint) -> CGPoint {
        let v = H * SIMD3<Float>(Float(point.x), Float(point.y), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }

    // Unit-square court corners in [TL, TR, BL, BR] order.
    private let unitSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1),
        CGPoint(x: 1, y: 1),
    ]

    // Allowed tolerance for all AC1–AC3 round-trip checks.
    private let eps: Float = 1e-4

    // MARK: - AC1: identity mapping

    func testAC1_identityMapping() throws {
        // imagePoints == courtPoints == unit-square corners → H maps each to itself.
        let H = try XCTUnwrap(
            HomographyService.compute(imagePoints: unitSquare, courtPoints: unitSquare),
            "AC1: compute returned nil for identity input"
        )

        let expected = unitSquare
        for (imgPt, expectedPt) in zip(unitSquare, expected) {
            let got = apply(H, to: imgPt)
            XCTAssertEqual(Float(got.x), Float(expectedPt.x), accuracy: eps,
                           "AC1: x mismatch for point \(imgPt)")
            XCTAssertEqual(Float(got.y), Float(expectedPt.y), accuracy: eps,
                           "AC1: y mismatch for point \(imgPt)")
        }
    }

    // MARK: - AC2: offset scaled rect (load-bearing transpose guard)

    func testAC2_offsetScaledRectForwardRoundTrip() throws {
        // Non-zero origin is deliberate — an origin-anchored rect yields a
        // diagonal matrix that is transpose-invariant and cannot catch the
        // row/col-major transposition bug.
        let imagePoints: [CGPoint] = [
            CGPoint(x: 100,  y: 50),   // TL
            CGPoint(x: 1920, y: 50),   // TR
            CGPoint(x: 100,  y: 1080), // BL
            CGPoint(x: 1920, y: 1080), // BR
        ]

        let H = try XCTUnwrap(
            HomographyService.compute(imagePoints: imagePoints, courtPoints: unitSquare),
            "AC2: compute returned nil for offset-rect input"
        )

        // Each corner must map to the corresponding unit-square corner.
        let expectedCorners: [CGPoint] = unitSquare
        for (imgPt, expectedPt) in zip(imagePoints, expectedCorners) {
            let got = apply(H, to: imgPt)
            XCTAssertEqual(Float(got.x), Float(expectedPt.x), accuracy: eps,
                           "AC2 corner: x mismatch for image point \(imgPt)")
            XCTAssertEqual(Float(got.y), Float(expectedPt.y), accuracy: eps,
                           "AC2 corner: y mismatch for image point \(imgPt)")
        }

        // Image center must map to court center (0.5, 0.5).
        // center.x = (100 + 1920) / 2 = 1010, center.y = (50 + 1080) / 2 = 565
        let imageCenter = CGPoint(x: 1010, y: 565)
        let gotCenter = apply(H, to: imageCenter)
        XCTAssertEqual(Float(gotCenter.x), 0.5, accuracy: eps,
                       "AC2 center: x expected 0.5 but got \(gotCenter.x)")
        XCTAssertEqual(Float(gotCenter.y), 0.5, accuracy: eps,
                       "AC2 center: y expected 0.5 but got \(gotCenter.y)")
    }

    // MARK: - AC3: perspective trapezoid (non-affine, load-bearing transpose guard)

    func testAC3_perspectiveTrapezoidForwardRoundTrip() throws {
        // Keystoned quad — no three points are collinear; not axis-aligned.
        // This guards genuine perspective mapping, not just affine scaling.
        let imagePoints: [CGPoint] = [
            CGPoint(x: 300,  y: 100),  // TL (inset)
            CGPoint(x: 1600, y: 100),  // TR (inset)
            CGPoint(x: 100,  y: 1000), // BL (wider)
            CGPoint(x: 1800, y: 1000), // BR (wider)
        ]

        let H = try XCTUnwrap(
            HomographyService.compute(imagePoints: imagePoints, courtPoints: unitSquare),
            "AC3: compute returned nil for trapezoid input"
        )

        // Each of the four image points must map to its corresponding unit-square corner.
        for (imgPt, expectedPt) in zip(imagePoints, unitSquare) {
            let got = apply(H, to: imgPt)
            XCTAssertEqual(Float(got.x), Float(expectedPt.x), accuracy: eps,
                           "AC3: x mismatch for image point \(imgPt)")
            XCTAssertEqual(Float(got.y), Float(expectedPt.y), accuracy: eps,
                           "AC3: y mismatch for image point \(imgPt)")
        }
    }

    // MARK: - AC4: degenerate (collinear) input → nil

    func testAC4_collinearImagePointsReturnsNil() {
        // Three of the four image points are collinear: (0,0),(1,1),(2,2),(3,0).
        // Court points are a valid unit square (count == 4) so the guard is the
        // singular-ratio criterion inside the DLT/SVD path, not the count guard.
        let collinearImagePoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 2, y: 2),
            CGPoint(x: 3, y: 0),
        ]
        let result = HomographyService.compute(
            imagePoints: collinearImagePoints,
            courtPoints: unitSquare
        )
        XCTAssertNil(result, "AC4: expected nil for collinear image points")
    }

    // MARK: - AC5: wrong count (either list) → nil

    func testAC5_wrongCountImagePointsReturnsNil() {
        let threePoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
        ]
        XCTAssertNil(
            HomographyService.compute(imagePoints: threePoints, courtPoints: unitSquare),
            "AC5: expected nil for 3 image points"
        )

        let fivePoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.5, y: 0.5),
        ]
        XCTAssertNil(
            HomographyService.compute(imagePoints: fivePoints, courtPoints: unitSquare),
            "AC5: expected nil for 5 image points"
        )
    }

    func testAC5_wrongCountCourtPointsReturnsNil() {
        let threeCourtPoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
        ]
        XCTAssertNil(
            HomographyService.compute(imagePoints: unitSquare, courtPoints: threeCourtPoints),
            "AC5: expected nil for 3 court points"
        )

        let fiveCourtPoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.5, y: 0.5),
        ]
        XCTAssertNil(
            HomographyService.compute(imagePoints: unitSquare, courtPoints: fiveCourtPoints),
            "AC5: expected nil for 5 court points"
        )
    }

    // MARK: - AC6: mismatched counts → nil

    func testAC6_mismatchedCountsReturnsNil() {
        let twoPoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
        ]
        let fivePoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.5, y: 0.5),
        ]

        // 2 image vs 5 court
        XCTAssertNil(
            HomographyService.compute(imagePoints: twoPoints, courtPoints: fivePoints),
            "AC6: expected nil for 2 vs 5 points"
        )

        // 5 image vs 2 court
        XCTAssertNil(
            HomographyService.compute(imagePoints: fivePoints, courtPoints: twoPoints),
            "AC6: expected nil for 5 vs 2 points"
        )

        // 4 image vs 3 court
        let threeCourtPoints: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
        ]
        XCTAssertNil(
            HomographyService.compute(imagePoints: unitSquare, courtPoints: threeCourtPoints),
            "AC6: expected nil for 4 vs 3 points"
        )
    }
}

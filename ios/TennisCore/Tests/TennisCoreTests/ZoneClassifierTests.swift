import XCTest
import CoreGraphics
@testable import TennisCore

final class ZoneClassifierTests: XCTestCase {

    // Standard 120×120 rect used by most tests.
    private let rect = CGRect(x: 0, y: 0, width: 120, height: 120)

    // Six valid zone strings (AC23 membership set).
    private let validZones: Set<String> = [
        "front_court_left",
        "front_court_right",
        "baseline_left",
        "baseline_right",
        "out_left",
        "out_right"
    ]

    // MARK: - AC18: six cell centers map 1:1 to six zone strings

    func testAC18_sixCellCentersMapToSixZones() {
        // Column centers: left x=30 (< midX=60), right x=90 (>= midX=60)
        // Row centers:    near-net y=20 (< 40), mid y=60 (40<=y<80), deep y=100 (>= 80)
        let cases: [(CGPoint, String)] = [
            (CGPoint(x: 30, y: 20),  "front_court_left"),
            (CGPoint(x: 90, y: 20),  "front_court_right"),
            (CGPoint(x: 30, y: 60),  "baseline_left"),
            (CGPoint(x: 90, y: 60),  "baseline_right"),
            (CGPoint(x: 30, y: 100), "out_left"),
            (CGPoint(x: 90, y: 100), "out_right"),
        ]
        for (point, expected) in cases {
            let result = ZoneClassifier.classify(point: point, in: rect)
            XCTAssertEqual(result, expected,
                           "center \(point) expected \(expected) but got \(result)")
        }
    }

    // MARK: - AC19: x == midX (60) is right-owned

    func testAC19_midXIsRightOwned() {
        // x=60 == midX=60 → >= midX is true → right column
        // y=20 is in near-net row (< 40) → front_court_right
        let result = ZoneClassifier.classify(point: CGPoint(x: 60, y: 20), in: rect)
        XCTAssertEqual(result, "front_court_right")
    }

    // MARK: - AC20: y == h/3 → mid row; y == 2h/3 → deep row

    func testAC20_rowBoundaryOwnership() {
        // h/3 = 40: strict < means y=40 falls into mid row, not near-net
        let midRowResult = ZoneClassifier.classify(point: CGPoint(x: 30, y: 40), in: rect)
        XCTAssertEqual(midRowResult, "baseline_left",
                       "y=h/3=40 should be in mid row (baseline_left), not near-net")

        // 2h/3 = 80: strict < means y=80 falls into deep row, not mid
        let deepRowResult = ZoneClassifier.classify(point: CGPoint(x: 30, y: 80), in: rect)
        XCTAssertEqual(deepRowResult, "out_left",
                       "y=2h/3=80 should be in deep row (out_left), not mid")
    }

    // MARK: - AC21: four corners

    func testAC21_fourCornersResolveCorrectly() {
        // top-left (0,0): clamps to (0,0), x<60 left, y<40 near-net → front_court_left
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 0, y: 0), in: rect),
            "front_court_left"
        )
        // top-right (120,0): clamps to (120,0), x>=60 right, y<40 near-net → front_court_right
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 120, y: 0), in: rect),
            "front_court_right"
        )
        // bottom-left (0,120): clamps to (0,120), x<60 left, y>=80 deep → out_left
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 0, y: 120), in: rect),
            "out_left"
        )
        // bottom-right (120,120): clamps to (120,120), x>=60 right, y>=80 deep → out_right
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 120, y: 120), in: rect),
            "out_right"
        )
    }

    // MARK: - AC22: out-of-rect points clamp to a valid zone

    func testAC22_outOfRectPointsClamp() {
        // (-10,-10): clamps to (0,0) → front_court_left
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: -10, y: -10), in: rect),
            "front_court_left"
        )
        // (999,999): clamps to (120,120) → out_right
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 999, y: 999), in: rect),
            "out_right"
        )
    }

    // MARK: - AC23: grid sweep never returns a string outside the six-value set

    func testAC23_gridSweepNeverReturnsInvalidZone() {
        // Step across both inside and outside the rect so clamping is exercised.
        let xs: [CGFloat] = [-30, 0, 15, 30, 59, 60, 61, 90, 120, 150]
        let ys: [CGFloat] = [-30, 0, 10, 20, 39, 40, 41, 60, 79, 80, 81, 100, 120, 150]
        for x in xs {
            for y in ys {
                let result = ZoneClassifier.classify(point: CGPoint(x: x, y: y), in: rect)
                XCTAssertTrue(
                    validZones.contains(result),
                    "classify(\(x),\(y)) returned \"\(result)\" which is not in the six-zone set"
                )
            }
        }
    }

    // MARK: - OQ-2: degenerate rects return front_court_left

    func testOQ2_degenerateRectsReturnFrontCourtLeft() {
        // width == 0
        let zeroWidth = CGRect(x: 0, y: 0, width: 0, height: 120)
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 0, y: 0), in: zeroWidth),
            "front_court_left"
        )
        // height == 0
        let zeroHeight = CGRect(x: 0, y: 0, width: 120, height: 0)
        XCTAssertEqual(
            ZoneClassifier.classify(point: CGPoint(x: 0, y: 0), in: zeroHeight),
            "front_court_left"
        )
    }
}

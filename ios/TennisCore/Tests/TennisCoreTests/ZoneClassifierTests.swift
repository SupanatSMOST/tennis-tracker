import XCTest
import CoreGraphics
@testable import TennisCore

final class ZoneClassifierTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 120, height: 120)

    func testSevenZoneClassificationIncludingBehindBaseline() {
        let cases: [(CGPoint, String)] = [
            (CGPoint(x: 30, y: 20), "front_court_left"),
            (CGPoint(x: 90, y: 20), "front_court_right"),
            (CGPoint(x: 30, y: 60), "baseline_left"),
            (CGPoint(x: 90, y: 60), "baseline_right"),
            (CGPoint(x: 30, y: 100), "out_left"),
            (CGPoint(x: 90, y: 100), "out_right"),
            (CGPoint(x: 60, y: 120.01), "out_behind"),
            (CGPoint(x: -100, y: 121), "out_behind"),
            (CGPoint(x: 999, y: 999), "out_behind")
        ]
        for (point, expected) in cases {
            XCTAssertEqual(ZoneClassifier.classify(point: point, in: rect), expected, "point: \\(point)")
        }
    }

    func testBaselineBoundaryRemainsInDeepCourtRow() {
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: 30, y: 120), in: rect), "out_left")
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: 90, y: 120), in: rect), "out_right")
    }

    func testHorizontalOutOfCourtStillClampsToSideZone() {
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: -10, y: 100), in: rect), "out_left")
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: 999, y: 100), in: rect), "out_right")
    }

    func testInvalidOrDegenerateGeometryUsesFallback() {
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: 0, y: 0), in: CGRect(x: 0, y: 0, width: 0, height: 120)), "front_court_left")
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: 0, y: 0), in: CGRect(x: 0, y: 0, width: 120, height: 0)), "front_court_left")
        XCTAssertEqual(ZoneClassifier.classify(point: CGPoint(x: .nan, y: 1), in: rect), "front_court_left")
    }
}

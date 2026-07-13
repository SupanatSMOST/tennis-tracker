/// CalibrationStoreTests — hermetic tests for Task 2 (CalibrationStore + CourtCalibration).
///
/// Each test injects a unique temp baseDirectory and removes it in tearDown.
/// No writes ever reach the real ~/Documents directory.
///
/// Coverage: AC7 (round-trip), AC8 (unknown id → nil), AC9 (delete),
///           AC10 (JSON shape), AC10a (row-major order — the load-bearing transpose guard).

import XCTest
import CoreGraphics
import simd
@testable import TennisCore

final class CalibrationStoreTests: XCTestCase {

    // MARK: - Per-test isolation

    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        // Unique temp directory per test — never writes to ~/Documents (A-4 / plan §2.1.3).
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let dir = baseDir {
            try? FileManager.default.removeItem(at: dir)
        }
        baseDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> CalibrationStore {
        CalibrationStore(baseDirectory: baseDir)
    }

    /// Unit-square court corners in [TL, TR, BL, BR] order.
    private let unitSquarePoints: [CGPointCodable] = [
        CGPointCodable(x: 0, y: 0),
        CGPointCodable(x: 1, y: 0),
        CGPointCodable(x: 0, y: 1),
        CGPointCodable(x: 1, y: 1),
    ]

    private let unitSquareCGPoints: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1),
        CGPoint(x: 1, y: 1),
    ]

    /// AC2 offset-rect image points — non-zero origin makes the matrix non-diagonal,
    /// which is what makes it able to catch a column-major vs row-major bug (AC10a).
    private let offsetRectImagePoints: [CGPoint] = [
        CGPoint(x: 100,  y: 50),    // TL
        CGPoint(x: 1920, y: 50),    // TR
        CGPoint(x: 100,  y: 1080),  // BL
        CGPoint(x: 1920, y: 1080),  // BR
    ]

    private let offsetRectImagePointsCodable: [CGPointCodable] = [
        CGPointCodable(x: 100,  y: 50),
        CGPointCodable(x: 1920, y: 50),
        CGPointCodable(x: 100,  y: 1080),
        CGPointCodable(x: 1920, y: 1080),
    ]

    /// Float epsilon for matrix comparisons (JSON encoding/decoding can shift low bits).
    private let matrixEps: Float = 1e-5

    // MARK: - AC7: save then load → equal value

    func testAC7_roundTrip_saveAndLoad_returnsEqualCalibration() throws {
        let store = makeStore()
        let matchId = "match-ac7"

        // Build a CourtCalibration using the Codable-synthesized init (not homography:)
        // to avoid coupling AC7 to AC10a. The nine floats are arbitrary but distinct.
        let matrix: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 1]
        let original = CourtCalibration(
            matchId: matchId,
            imagePoints: offsetRectImagePointsCodable,
            courtPoints: unitSquarePoints,
            homographyMatrix: matrix
        )

        try store.save(original)
        let loaded = try XCTUnwrap(
            store.load(for: matchId),
            "AC7: load returned nil after a successful save"
        )

        // Points round-trip exactly (Doubles through JSON).
        XCTAssertEqual(loaded.matchId, original.matchId, "AC7: matchId mismatch after round-trip")
        XCTAssertEqual(loaded.imagePoints, original.imagePoints, "AC7: imagePoints mismatch after round-trip")
        XCTAssertEqual(loaded.courtPoints, original.courtPoints, "AC7: courtPoints mismatch after round-trip")

        // Floats compared element-wise within epsilon (JSON numeric encoding may shift low bits).
        XCTAssertEqual(loaded.homographyMatrix.count, 9, "AC7: homographyMatrix must have 9 elements")
        for i in 0..<9 {
            XCTAssertEqual(
                loaded.homographyMatrix[i],
                original.homographyMatrix[i],
                accuracy: matrixEps,
                "AC7: homographyMatrix[\(i)] mismatch after round-trip"
            )
        }
    }

    // MARK: - AC8: unknown matchId → nil (not throw, not crash)

    func testAC8_unknownMatchId_returnsNil() {
        let store = makeStore()
        // No save() call — this matchId has never been persisted.
        let result = store.load(for: "never-saved-match")
        XCTAssertNil(result, "AC8: load for an unsaved matchId must return nil, not throw")
    }

    // MARK: - AC9: delete removes file; absent delete does not throw

    func testAC9_delete_removesCalibrationAndExistsBecomesFalse() throws {
        let store = makeStore()
        let matchId = "match-ac9"

        let matrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let cal = CourtCalibration(
            matchId: matchId,
            imagePoints: offsetRectImagePointsCodable,
            courtPoints: unitSquarePoints,
            homographyMatrix: matrix
        )

        try store.save(cal)
        XCTAssertTrue(store.exists(for: matchId), "AC9 precondition: exists must be true after save")
        XCTAssertNotNil(store.load(for: matchId), "AC9 precondition: load must succeed after save")

        try store.delete(for: matchId)

        XCTAssertFalse(store.exists(for: matchId), "AC9: exists must be false after delete")
        XCTAssertNil(store.load(for: matchId), "AC9: load must return nil after delete")
    }

    func testAC9_deleteOnAbsentCalibration_doesNotThrow() {
        let store = makeStore()
        // delete on a matchId that was never saved must not throw.
        XCTAssertNoThrow(
            try store.delete(for: "nonexistent-match"),
            "AC9: delete on a nonexistent calibration must not throw"
        )
    }

    // MARK: - AC10: JSON encodes points as {"x":..,"y":..} and homographyMatrix as flat 9-array

    func testAC10_jsonShape_pointsAndMatrix() throws {
        let matchId = "match-ac10"
        let matrix: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 1]
        let cal = CourtCalibration(
            matchId: matchId,
            imagePoints: offsetRectImagePointsCodable,
            courtPoints: unitSquarePoints,
            homographyMatrix: matrix
        )

        let data = try JSONEncoder().encode(cal)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "AC10: top-level JSON must be an object"
        )

        // Each imagePoint must serialize as {"x": <number>, "y": <number>}.
        let imagePtsRaw = try XCTUnwrap(
            json["imagePoints"] as? [[String: Any]],
            "AC10: imagePoints must be a JSON array of objects"
        )
        XCTAssertEqual(imagePtsRaw.count, 4, "AC10: imagePoints must contain 4 elements")
        for (i, pt) in imagePtsRaw.enumerated() {
            XCTAssertNotNil(pt["x"], "AC10: imagePoints[\(i)] missing key 'x'")
            XCTAssertNotNil(pt["y"], "AC10: imagePoints[\(i)] missing key 'y'")
            XCTAssertEqual(pt.keys.count, 2, "AC10: imagePoints[\(i)] must have exactly keys x,y — got \(pt.keys)")
        }

        // Each courtPoint must also serialize as {"x":.., "y":..}.
        let courtPtsRaw = try XCTUnwrap(
            json["courtPoints"] as? [[String: Any]],
            "AC10: courtPoints must be a JSON array of objects"
        )
        XCTAssertEqual(courtPtsRaw.count, 4, "AC10: courtPoints must contain 4 elements")
        for (i, pt) in courtPtsRaw.enumerated() {
            XCTAssertNotNil(pt["x"], "AC10: courtPoints[\(i)] missing key 'x'")
            XCTAssertNotNil(pt["y"], "AC10: courtPoints[\(i)] missing key 'y'")
        }

        // homographyMatrix must be a flat JSON array of 9 numbers.
        let matrixRaw = try XCTUnwrap(
            json["homographyMatrix"] as? [Any],
            "AC10: homographyMatrix must be a JSON array"
        )
        XCTAssertEqual(matrixRaw.count, 9, "AC10: homographyMatrix must have exactly 9 elements")
        for (i, elem) in matrixRaw.enumerated() {
            XCTAssertTrue(
                elem is NSNumber,
                "AC10: homographyMatrix[\(i)] must be a number, got \(type(of: elem))"
            )
        }

        // Must decode back to an equal value (point-wise exact, matrix within epsilon).
        let decoded = try JSONDecoder().decode(CourtCalibration.self, from: data)
        XCTAssertEqual(decoded.matchId, cal.matchId, "AC10: decoded matchId mismatch")
        XCTAssertEqual(decoded.imagePoints, cal.imagePoints, "AC10: decoded imagePoints mismatch")
        XCTAssertEqual(decoded.homographyMatrix.count, 9, "AC10: decoded matrix must have 9 elements")
        for i in 0..<9 {
            XCTAssertEqual(
                decoded.homographyMatrix[i],
                cal.homographyMatrix[i],
                accuracy: matrixEps,
                "AC10: decoded homographyMatrix[\(i)] mismatch"
            )
        }
    }

    // MARK: - AC10a: row-major order — load-bearing transpose guard

    /// This test is specifically designed to catch a column-major flatten bug.
    ///
    /// The AC2 offset-rect homography is non-diagonal (non-zero tx, ty), so
    /// the row-major and column-major orderings differ at indices 2,5,6,7.
    /// A column-major flatten would produce [sx,0,0, 0,sy,0, tx,ty,1]
    /// while correct row-major gives [sx,0,tx, 0,sy,ty, 0,0,1].
    ///
    /// We derive `expected[3*r+c]` directly from the simd matrix as `H[c][r]`
    /// (element (r,c) of a column-major simd_float3x3 is H[c][r]).
    /// This side is independent of CalibrationStore's flattening code.
    func testAC10a_rowMajorFlatten_nonDiagonalHomography() throws {
        // Compute the homography for the AC2 offset rect (non-diagonal, non-zero origin).
        let H = try XCTUnwrap(
            HomographyService.compute(
                imagePoints: offsetRectImagePoints,
                courtPoints: unitSquareCGPoints
            ),
            "AC10a: HomographyService.compute returned nil for offset-rect input"
        )

        // Build the calibration through the shared conversion seam.
        let cal = CourtCalibration(
            matchId: "match-ac10a",
            imagePoints: offsetRectImagePointsCodable,
            courtPoints: unitSquarePoints,
            homography: H
        )

        XCTAssertEqual(cal.homographyMatrix.count, 9, "AC10a: homographyMatrix must have 9 elements")

        // Derive expected values directly from the simd matrix:
        // For column-major simd_float3x3: element at (row r, col c) == H[c][r].
        // Row-major index: expected[3*r + c] == H[c][r].
        // This is independent of the store's flatten loop.
        for r in 0..<3 {
            for c in 0..<3 {
                let expected = H[c][r]   // direct simd element read: (row r, col c)
                let actual = cal.homographyMatrix[3 * r + c]
                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: matrixEps,
                    "AC10a: homographyMatrix[\(3*r+c)] (row \(r), col \(c)): expected \(expected), got \(actual)"
                )
            }
        }

        // h22 must be normalized to 1.0.
        XCTAssertEqual(
            cal.homographyMatrix[8],
            1.0,
            accuracy: matrixEps,
            "AC10a: h22 (index 8) must be normalized to 1.0, got \(cal.homographyMatrix[8])"
        )

        // Spot-check: indices 2 and 6 (h02 = tx, h20 = 0 in an affine rect homography)
        // must NOT both be zero — confirming the matrix is truly non-diagonal.
        let h02 = cal.homographyMatrix[2]  // should be non-zero tx
        let h20 = cal.homographyMatrix[6]  // should be near 0
        // tx = -100/(1820) ≠ 0 for the offset rect; h02 and h20 differ.
        XCTAssertNotEqual(
            h02, h20, accuracy: matrixEps,
            "AC10a: h02 and h20 must differ for the non-diagonal offset-rect matrix — matrix may be diagonal/identity"
        )
    }
}

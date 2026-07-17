/// CalibrationStore — persists and loads CourtCalibration for a match.
///
/// `CourtCalibration` stores the 4-corner image/court point pairs and the
/// computed 3×3 homography as a **row-major** `[Float]` array.  The single
/// `init(matchId:imagePoints:courtPoints:homography:)` conversion seam
/// (see below) is the only place the simd column-major matrix is flattened
/// to row-major — keeping the HomographyService result and the persisted
/// bytes in sync.
///
/// Path layout: `<baseDirectory ?? Documents>/calibrations/{matchId}.json`
/// The `calibrations/` directory is created on first `save`.

import Foundation
import simd

// MARK: - CGPointCodable

/// A `Codable`, `Equatable` representation of a 2-D point.
///
/// Used instead of `CGPoint` to avoid an `import CoreGraphics` dependency in
/// the file-store layer (CoreGraphics is only needed by the VM / view layer).
/// JSON shape: `{"x":<Double>,"y":<Double>}` (AC10).
public struct CGPointCodable: Codable, Equatable {
    public var x: Double
    public var y: Double

    // Explicit public init — required so callers outside the module can
    // construct values even when using plain `import TennisCore` (not
    // @testable). The synthesized memberwise init is `internal` for a
    // `public` struct.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - CourtCalibration

/// The persisted output of the court-calibration step.
///
/// - `imagePoints`: four image-fraction-coord corners in `[TL, TR, BL, BR]` order.
/// - `courtPoints`: always `[(0,0),(1,0),(0,1),(1,1)]` (the unit-square court).
/// - `homographyMatrix`: 9-element **row-major** flatten of the 3×3 homography,
///   `[h00,h01,h02, h10,h11,h12, h20,h21,h22]`, with `h22 == 1`.
public struct CourtCalibration: Codable, Equatable {
    public let matchId: String
    public let imagePoints: [CGPointCodable]    // [TL, TR, BL, BR], image-fraction coords
    public let courtPoints: [CGPointCodable]    // always [(0,0),(1,0),(0,1),(1,1)]
    public let homographyMatrix: [Float]         // 9 elements, ROW-MAJOR (AC10)
}

// MARK: CourtCalibration + homography init (THE shared conversion seam)

extension CourtCalibration {

    /// Constructs a `CourtCalibration` from a `simd_float3x3` homography.
    ///
    /// This is **the** single conversion seam between the simd column-major
    /// matrix and the persisted row-major `[Float]` array (plan §2.1.2).
    /// Routing all flattening through here ensures the VM (AC21) and the
    /// AC10a store test use identical code — a transpose slip cannot diverge
    /// between production and tests.
    ///
    /// **Row-major flatten:**  element `(row r, col c)` of a column-major
    /// `simd_float3x3` is `H[c][r]`.  So `out[3*r + c] = H[c][r]` gives
    /// `[h00,h01,h02, h10,h11,h12, h20,h21,h22]`.
    public init(
        matchId: String,
        imagePoints: [CGPointCodable],
        courtPoints: [CGPointCodable],
        homography H: simd_float3x3
    ) {
        self.matchId = matchId
        self.imagePoints = imagePoints
        self.courtPoints = courtPoints
        // Transpose point: simd_float3x3 is column-major; H[c][r] is element (r,c).
        // out[3*r + c] = H[c][r]  →  row-major [h00,h01,h02, h10,h11,h12, h20,h21,h22]
        var out = [Float]()
        out.reserveCapacity(9)
        for r in 0..<3 {
            for c in 0..<3 {
                out.append(H[c][r])
            }
        }
        self.homographyMatrix = out
    }
}

// MARK: - CalibrationStore

/// File-backed store for `CourtCalibration` values.
///
/// Thread-safety: not thread-safe — each caller owns its own instance and
/// must synchronise externally if needed.  In practice this is called from
/// a single VM on the main actor, so no lock is required.
public struct CalibrationStore {

    private let baseDirectory: URL

    // MARK: Init

    /// - Parameter baseDirectory: Override the directory for test isolation
    ///   (plan §2.1.3 / A-4).  Defaults to the app's `Documents` directory.
    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            self.baseDirectory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
    }

    // MARK: Helpers

    private var calibrationsDir: URL {
        baseDirectory.appendingPathComponent("calibrations", isDirectory: true)
    }

    private func fileURL(for matchId: String) -> URL {
        calibrationsDir.appendingPathComponent("\(matchId).json")
    }

    // MARK: API

    /// Persists `calibration` to `calibrations/{matchId}.json`.
    ///
    /// Creates the `calibrations/` directory if it does not yet exist.
    /// Overwrites any existing file for the same `matchId` (OQ-7).
    public func save(_ calibration: CourtCalibration) throws {
        let dir = calibrationsDir
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONEncoder().encode(calibration)
        try data.write(to: fileURL(for: calibration.matchId), options: .atomic)
    }

    /// Returns the stored `CourtCalibration` for `matchId`, or `nil` if none
    /// exists or if the file cannot be decoded (AC8 — never throws).
    public func load(for matchId: String) -> CourtCalibration? {
        guard let data = try? Data(contentsOf: fileURL(for: matchId)) else {
            return nil
        }
        return try? JSONDecoder().decode(CourtCalibration.self, from: data)
    }

    /// Returns `true` if a calibration file exists for `matchId`.
    public func exists(for matchId: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: matchId).path)
    }

    /// Removes the calibration file for `matchId`.
    ///
    /// No-op if the file is absent (AC9).
    public func delete(for matchId: String) throws {
        let url = fileURL(for: matchId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

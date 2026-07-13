/// CameraSessionViewModelTests — hermetic XCTest coverage for Task 5.
///
/// Covers AC13–AC23 (one test per AC13–AC22, plus the full-walk AC23).
/// Uses MockCameraService for the camera dependency and injects a unique
/// temp baseDirectory into both CalibrationStore and LocalVideoStore per test.
/// No writes ever reach the real ~/Documents directory.

import XCTest
import CoreGraphics
import simd
@testable import TennisCore

final class CameraSessionViewModelTests: XCTestCase {

    // MARK: - Per-test isolation

    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        // Unique temp directory per test — never writes to ~/Documents.
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

    /// Builds a fresh VM wired to the given mock + temp-dir stores.
    private func makeVM(
        mock: MockCameraService = MockCameraService()
    ) -> (vm: CameraSessionViewModel, mock: MockCameraService) {
        let calibStore = CalibrationStore(baseDirectory: baseDir)
        let videoStore = LocalVideoStore(baseDirectory: baseDir)
        let vm = CameraSessionViewModel(
            camera: mock,
            calibrationStore: calibStore,
            videoStore: videoStore
        )
        return (vm, mock)
    }

    /// Unit-square court corners in [TL, TR, BL, BR] order.
    private let unitSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 1),
        CGPoint(x: 1, y: 1),
    ]

    /// Four pixel taps that form a valid non-degenerate quad (offset rect).
    ///
    /// image size: 2000 × 1200
    /// fraction TL: (100/2000, 50/1200) = (0.05, ~0.0417)
    /// fraction TR: (1920/2000, 50/1200) = (0.96, ~0.0417)
    /// fraction BL: (100/2000, 1080/1200) = (0.05, 0.90)
    /// fraction BR: (1920/2000, 1080/1200) = (0.96, 0.90)
    private let quadPixelTaps: [(x: CGFloat, y: CGFloat)] = [
        (100,  50),    // TL
        (1920, 50),    // TR
        (100,  1080),  // BL
        (1920, 1080),  // BR
    ]
    private let quadImageSize = CGSize(width: 2000, height: 1200)

    /// Taps all four corners using `quadPixelTaps` / `quadImageSize`.
    private func tapQuad(on vm: CameraSessionViewModel) {
        for tap in quadPixelTaps {
            vm.tapCorner(
                at: CGPoint(x: tap.x, y: tap.y),
                imageSize: quadImageSize
            )
        }
    }

    /// Element-wise epsilon for simd_float3x3 comparisons.
    private let matrixEps: Float = 1e-4

    // MARK: - AC13: initial state is .permissionPending

    func testAC13_initialState_isPermissionPending() {
        let (vm, _) = makeVM()
        XCTAssertEqual(
            vm.state,
            .permissionPending,
            "AC13: fresh CameraSessionViewModel must start in .permissionPending"
        )
    }

    // MARK: - AC14: permission granted → .previewing

    func testAC14_startPreview_permissionGranted_transitionsToPrevieweing() async {
        let mock = MockCameraService()
        mock.permissionResult = true
        let (vm, _) = makeVM(mock: mock)

        await vm.startPreview()

        XCTAssertEqual(
            vm.state,
            .previewing,
            "AC14: after startPreview() with granted permission, state must be .previewing"
        )
    }

    // MARK: - AC15: permission denied → .permissionDenied, NOT .previewing

    func testAC15_startPreview_permissionDenied_transitionsToPermissionDenied() async {
        let mock = MockCameraService()
        mock.permissionResult = false
        let (vm, _) = makeVM(mock: mock)

        await vm.startPreview()

        XCTAssertEqual(
            vm.state,
            .permissionDenied,
            "AC15: after startPreview() with denied permission, state must be .permissionDenied"
        )
        XCTAssertNotEqual(
            vm.state,
            .previewing,
            "AC15: state must NOT be .previewing when permission is denied"
        )
    }

    // MARK: - AC16: three tapCorner calls → .tappingCorners(count:3), homography == nil

    func testAC16_threeTaps_tappingCornersCount3_homographyNil() async {
        let (vm, _) = makeVM()
        await vm.startPreview()

        for (i, tap) in quadPixelTaps.prefix(3).enumerated() {
            vm.tapCorner(at: CGPoint(x: tap.x, y: tap.y), imageSize: quadImageSize)
            XCTAssertEqual(
                vm.state,
                .tappingCorners(count: i + 1),
                "AC16: after tap \(i + 1), state must be .tappingCorners(count: \(i + 1))"
            )
            XCTAssertNil(
                vm.homography,
                "AC16: homography must remain nil before the 4th tap (after tap \(i + 1))"
            )
        }
    }

    // MARK: - AC17: fourth tap → .calibrated, homography non-nil and correct

    func testAC17_fourthTap_calibrated_homographyMatchesExpected() async throws {
        let (vm, _) = makeVM()
        await vm.startPreview()

        tapQuad(on: vm)

        XCTAssertEqual(vm.state, .calibrated, "AC17: state must be .calibrated after 4th tap")
        let H = try XCTUnwrap(vm.homography, "AC17: homography must be non-nil after 4th tap")

        // Derive expected by feeding the VM's own accumulated fraction points back
        // into HomographyService — same deterministic LAPACK call, same result.
        let expectedH = try XCTUnwrap(
            HomographyService.compute(
                imagePoints: vm.imagePoints,
                courtPoints: unitSquare
            ),
            "AC17: reference HomographyService.compute returned nil — test setup error (degenerate quad?)"
        )

        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(
                    H[c][r],
                    expectedH[c][r],
                    accuracy: matrixEps,
                    "AC17: H[\(c)][\(r)] == \(H[c][r]) expected \(expectedH[c][r])"
                )
            }
        }
    }

    // MARK: - AC18: accumulated image points are pixel/imageSize fractions in tap order

    func testAC18_imagePoints_areFractionCoordsInTapOrder() async {
        let (vm, _) = makeVM()
        await vm.startPreview()

        tapQuad(on: vm)

        XCTAssertEqual(vm.imagePoints.count, 4, "AC18: must have exactly 4 accumulated image points")

        for (i, tap) in quadPixelTaps.enumerated() {
            let expected = CGPoint(
                x: tap.x / quadImageSize.width,
                y: tap.y / quadImageSize.height
            )
            let actual = vm.imagePoints[i]
            XCTAssertEqual(
                actual.x,
                expected.x,
                accuracy: 1e-6,
                "AC18: imagePoints[\(i)].x fraction mismatch"
            )
            XCTAssertEqual(
                actual.y,
                expected.y,
                accuracy: 1e-6,
                "AC18: imagePoints[\(i)].y fraction mismatch"
            )
        }
    }

    // MARK: - AC19: startRecording → mock called, file exists, state == .recording

    func testAC19_startRecording_mockCalledAndFileExists_stateRecording() async throws {
        let mock = MockCameraService()
        let (vm, _) = makeVM(mock: mock)
        await vm.startPreview()
        tapQuad(on: vm)

        let matchId = "match-ac19"
        // startRecording is synchronous throws
        try vm.startRecording(matchId: matchId)

        XCTAssertNotNil(
            mock.startRecordingCalledWith,
            "AC19: mock.startRecordingCalledWith must be set after startRecording"
        )
        XCTAssertEqual(vm.state, .recording, "AC19: state must be .recording after startRecording")

        // The mock writes an empty file at the URL; verify via LocalVideoStore.
        let videoStore = LocalVideoStore(baseDirectory: baseDir)
        XCTAssertTrue(
            videoStore.exists(for: matchId),
            "AC19: video file must exist at the LocalVideoStore URL after mock.startRecording"
        )
    }

    // MARK: - AC20: stopRecording → mock.stopRecordingCalled, state == .done

    func testAC20_stopRecording_mockCalledAndStateDone() async throws {
        let mock = MockCameraService()
        let (vm, _) = makeVM(mock: mock)
        await vm.startPreview()
        tapQuad(on: vm)
        try vm.startRecording(matchId: "match-ac20")

        try await vm.stopRecording()

        XCTAssertTrue(
            mock.stopRecordingCalled,
            "AC20: mock.stopRecordingCalled must be true after stopRecording()"
        )
        XCTAssertEqual(vm.state, .done, "AC20: state must be .done after stopRecording()")
    }

    // MARK: - AC21: saveCalibration persists via CalibrationStore

    func testAC21_saveCalibration_persistsViaCalibrationStore() async throws {
        let (vm, _) = makeVM()
        await vm.startPreview()
        tapQuad(on: vm)

        let matchId = "match-ac21"
        try vm.saveCalibration(for: matchId)

        // Load back through a fresh store pointing at the same temp dir.
        let store = CalibrationStore(baseDirectory: baseDir)
        let loaded = try XCTUnwrap(
            store.load(for: matchId),
            "AC21: CalibrationStore.load must return a CourtCalibration after saveCalibration"
        )

        // Image points — stored as fractions, match vm.imagePoints.
        XCTAssertEqual(loaded.imagePoints.count, 4, "AC21: loaded imagePoints must have 4 elements")
        for (i, pt) in loaded.imagePoints.enumerated() {
            XCTAssertEqual(
                pt.x,
                Double(vm.imagePoints[i].x),
                accuracy: 1e-6,
                "AC21: loaded imagePoints[\(i)].x mismatch"
            )
            XCTAssertEqual(
                pt.y,
                Double(vm.imagePoints[i].y),
                accuracy: 1e-6,
                "AC21: loaded imagePoints[\(i)].y mismatch"
            )
        }

        // Court points — always unit square [(0,0),(1,0),(0,1),(1,1)].
        let expectedCourt: [(Double, Double)] = [(0, 0), (1, 0), (0, 1), (1, 1)]
        XCTAssertEqual(loaded.courtPoints.count, 4, "AC21: loaded courtPoints must have 4 elements")
        for (i, (ex, ey)) in expectedCourt.enumerated() {
            XCTAssertEqual(loaded.courtPoints[i].x, ex, accuracy: 1e-9, "AC21: courtPoints[\(i)].x mismatch")
            XCTAssertEqual(loaded.courtPoints[i].y, ey, accuracy: 1e-9, "AC21: courtPoints[\(i)].y mismatch")
        }

        // Homography matrix — 9 elements, h22 == 1.0.
        XCTAssertEqual(
            loaded.homographyMatrix.count,
            9,
            "AC21: loaded homographyMatrix must have 9 elements"
        )
        XCTAssertEqual(
            loaded.homographyMatrix[8],
            1.0,
            accuracy: 1e-5,
            "AC21: h22 (index 8) must be normalized to 1.0"
        )
    }

    // MARK: - AC22: tapCorner before permission is a no-op

    func testAC22_tapCornerBeforePermission_isNoOp() {
        let (vm, _) = makeVM()
        // State is .permissionPending — permission never requested.

        vm.tapCorner(
            at: CGPoint(x: 500, y: 300),
            imageSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(
            vm.state,
            .permissionPending,
            "AC22: tapCorner while .permissionPending must leave state unchanged"
        )
        XCTAssertTrue(
            vm.imagePoints.isEmpty,
            "AC22: tapCorner while .permissionPending must not accumulate any image points (got \(vm.imagePoints.count))"
        )
    }

    // MARK: - AC23: full state-machine walk in a single test

    func testAC23_fullStateMachineWalk() async throws {
        let mock = MockCameraService()
        mock.permissionResult = true
        let (vm, _) = makeVM(mock: mock)

        // .permissionPending (initial)
        XCTAssertEqual(vm.state, .permissionPending, "AC23 [initial]: state must be .permissionPending")

        // → .previewing
        await vm.startPreview()
        XCTAssertEqual(vm.state, .previewing, "AC23 [after startPreview]: state must be .previewing")

        // → .tappingCorners(1), .tappingCorners(2), .tappingCorners(3)
        for (i, tap) in quadPixelTaps.prefix(3).enumerated() {
            vm.tapCorner(at: CGPoint(x: tap.x, y: tap.y), imageSize: quadImageSize)
            XCTAssertEqual(
                vm.state,
                .tappingCorners(count: i + 1),
                "AC23 [after tap \(i + 1)]: state must be .tappingCorners(count: \(i + 1))"
            )
        }

        // 4th tap → .calibrated
        let lastTap = quadPixelTaps[3]
        vm.tapCorner(at: CGPoint(x: lastTap.x, y: lastTap.y), imageSize: quadImageSize)
        XCTAssertEqual(vm.state, .calibrated, "AC23 [after 4th tap]: state must be .calibrated")
        XCTAssertNotNil(vm.homography, "AC23 [after 4th tap]: homography must be non-nil")

        // → .recording
        let matchId = "match-ac23"
        try vm.startRecording(matchId: matchId)
        XCTAssertEqual(vm.state, .recording, "AC23 [after startRecording]: state must be .recording")

        // → .done
        try await vm.stopRecording()
        XCTAssertEqual(vm.state, .done, "AC23 [after stopRecording]: state must be .done")
    }
}

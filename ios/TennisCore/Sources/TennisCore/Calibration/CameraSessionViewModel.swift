/// CameraSessionViewModel — @Observable state machine for camera setup and recording.
///
/// Owns the full calibration-and-record lifecycle:
///   permissionPending → previewing → tappingCorners(1..3) → calibrated
///                                                          → recording → done
///   permissionPending → permissionDenied  (terminal — OQ-2)
///
/// All camera I/O flows through the injected `CameraCapturing` seam, so the
/// VM is fully testable on macOS using `MockCameraService` (swift test / A-2).
///
/// Dependencies are injected at init (mirrors `RecordSessionViewModel` DI style).

import Foundation
import CoreGraphics
import simd
import Observation

// MARK: - CameraSessionState

/// The state of the camera calibration and recording session.
public enum CameraSessionState: Equatable {
    /// Initial state — camera permission has not yet been requested.
    case permissionPending
    /// Terminal state — the user denied camera permission (OQ-2).
    case permissionDenied
    /// Camera is running; preview is live.
    case previewing
    /// User is tapping court corners; `count` corners have been tapped so far (1..3).
    case tappingCorners(count: Int)
    /// Four corners tapped; homography computed (AC17).
    case calibrated
    /// Recording to disk is active.
    case recording
    /// Recording has stopped successfully.
    case done
}

// MARK: - CameraSessionError

/// Errors thrown by `CameraSessionViewModel` methods.
public enum CameraSessionError: Error, Equatable {
    /// `saveCalibration(for:)` was called before four corners were tapped
    /// (homography is nil).
    case notCalibrated
}

// MARK: - CameraSessionViewModel

@Observable
public final class CameraSessionViewModel {

    // MARK: - Public state

    /// Current state of the session state machine (AC13–AC23).
    public private(set) var state: CameraSessionState = .permissionPending

    /// Accumulated image-fraction corner points in tap order (`[TL, TR, BL, BR]`).
    ///
    /// Each component is in `[0, 1]` — `x = px / imageWidth`, `y = py / imageHeight`,
    /// origin top-left (spec §4, OQ-4).  Non-nil only after all four taps.
    public private(set) var imagePoints: [CGPoint] = []

    /// The computed homography, non-nil after the fourth corner tap (AC17).
    ///
    /// `H * simd_float3(x, y, 1)` maps an image-fraction point to court-fraction
    /// coords (the forward-mapping convention Phase 3 will consume).
    public private(set) var homography: simd_float3x3?

    // MARK: - Dependencies

    /// The injected camera service.
    ///
    /// Exposed `public let` so Task 6 views can reach `camera.previewLayer` to
    /// wire the live preview layer into a `UIViewRepresentable`.
    public let camera: CameraCapturing

    private let calibrationStore: CalibrationStore
    private let videoStore: LocalVideoStore

    // MARK: - Private constants

    /// Unit-square court corners in `[TL, TR, BL, BR]` order (spec §5).
    private let unitSquare: [CGPoint] = [
        CGPoint(x: 0, y: 0),   // TL
        CGPoint(x: 1, y: 0),   // TR
        CGPoint(x: 0, y: 1),   // BL
        CGPoint(x: 1, y: 1),   // BR
    ]

    // MARK: - Init

    /// Creates a `CameraSessionViewModel` with injected dependencies.
    ///
    /// - Parameters:
    ///   - camera: The camera service (use `CameraService()` in the app,
    ///     `MockCameraService()` in tests).
    ///   - calibrationStore: Persists the computed `CourtCalibration`.
    ///     Defaults to the app `Documents` directory.
    ///   - videoStore: Resolves the on-device `.mov` URL.
    ///     Defaults to the app `Documents` directory.
    public init(
        camera: CameraCapturing,
        calibrationStore: CalibrationStore = CalibrationStore(),
        videoStore: LocalVideoStore = LocalVideoStore()
    ) {
        self.camera = camera
        self.calibrationStore = calibrationStore
        self.videoStore = videoStore
    }

    // MARK: - Actions

    /// Requests camera permission and, if granted, starts the preview.
    ///
    /// - Granted: calls `camera.startPreview()` (errors swallowed — no enum
    ///   case for preview failure), then transitions to `.previewing` (AC14).
    /// - Denied: transitions to `.permissionDenied`; never reaches `.previewing`
    ///   (AC15 / OQ-2).
    ///
    /// `startPreview()` is no-arg because the camera dependency was injected at
    /// init (Phase-1 DI precedent; plan §2.1.5 signature resolution).
    public func startPreview() async {
        let granted = await camera.requestPermission()
        guard granted else {
            state = .permissionDenied
            return
        }
        // ponytail: try? is intentional — startPreview() is async non-throwing;
        // no enum case models a preview-start failure and AC14/AC15 don't exercise
        // it. Upgrade path: add a .previewFailed state if hardware-unavailable
        // error handling becomes a requirement.
        try? camera.startPreview()
        state = .previewing
    }

    /// Records a tapped court corner in image-fraction coordinates.
    ///
    /// - Guard (OQ-3 / AC22): only acts when state is `.previewing` or
    ///   `.tappingCorners`; any other state is a no-op (including after the 4th
    ///   tap, so a 5th tap on `.calibrated` is silently ignored).
    /// - Converts pixel coords to fractions: `(x/w, y/h)`, origin top-left (§4).
    /// - After taps 1–3: transitions to `.tappingCorners(count: n)`, `homography`
    ///   remains nil (AC16).
    /// - On the 4th tap: computes the homography via `HomographyService.compute`
    ///   and transitions to `.calibrated` (AC17).
    ///
    /// - Parameters:
    ///   - point: The pixel location of the tap within the preview image.
    ///   - imageSize: The pixel size of the preview image.
    public func tapCorner(at point: CGPoint, imageSize: CGSize) {
        switch state {
        case .previewing, .tappingCorners:
            break   // allowed — fall through to processing
        default:
            return  // no-op (OQ-3 / AC22)
        }

        let fraction = CGPoint(
            x: point.x / imageSize.width,
            y: point.y / imageSize.height
        )
        imagePoints.append(fraction)

        let n = imagePoints.count
        if n < 4 {
            state = .tappingCorners(count: n)
        } else {
            // 4th tap — compute homography and advance to calibrated (AC17).
            homography = HomographyService.compute(
                imagePoints: imagePoints,
                courtPoints: unitSquare
            )
            state = .calibrated
        }
    }

    /// Resolves the video URL for `matchId` and begins recording.
    ///
    /// Transitions to `.recording` (AC19).
    ///
    /// - Throws: Any error propagated from `camera.startRecording(to:)`.
    public func startRecording(matchId: String) throws {
        let url = videoStore.videoURL(for: matchId)
        try camera.startRecording(to: url)
        state = .recording
    }

    /// Stops the in-progress recording and waits for the file to be finalised.
    ///
    /// Transitions to `.done` (AC20).
    ///
    /// - Throws: Any error propagated from `camera.stopRecording()`.
    public func stopRecording() async throws {
        try await camera.stopRecording()
        state = .done
    }

    /// Persists the computed calibration for `matchId` via `CalibrationStore`.
    ///
    /// Builds a `CourtCalibration` through the **shared** `homography:` init
    /// (plan §2.1.2 — the single simd→row-major conversion seam) and writes it
    /// to disk (AC21).
    ///
    /// - Throws: `CameraSessionError.notCalibrated` if called before the
    ///   homography has been computed (i.e. fewer than four corners tapped).
    ///   Also propagates any `CalibrationStore.save(_:)` I/O error.
    public func saveCalibration(for matchId: String) throws {
        guard let h = homography else {
            throw CameraSessionError.notCalibrated
        }

        let codableImagePoints = imagePoints.map { CGPointCodable(x: Double($0.x), y: Double($0.y)) }
        let codableCourtPoints = unitSquare.map { CGPointCodable(x: Double($0.x), y: Double($0.y)) }

        let calibration = CourtCalibration(
            matchId: matchId,
            imagePoints: codableImagePoints,
            courtPoints: codableCourtPoints,
            homography: h
        )
        try calibrationStore.save(calibration)
    }
}

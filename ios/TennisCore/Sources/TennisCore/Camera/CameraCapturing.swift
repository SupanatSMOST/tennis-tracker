/// CameraCapturing — the capture seam protocol.
///
/// This protocol abstracts all camera I/O so that:
///   - `CameraSessionViewModel` (in TennisCore) can be tested on macOS with
///     `MockCameraService` (no iOS runtime required — A-2 gate).
///   - The concrete `CameraService` (AVFoundation, iOS-only) is substituted
///     transparently at the app layer.
///
/// Import note: `AVFoundation` is legitimately imported here.
/// The §2.2 AVFoundation/UIKit/CoreImage/Vision ban applies ONLY to
/// `HomographyService.swift` (AC29).  `CameraCapturing` depends on
/// `AVCaptureVideoPreviewLayer`, which is available on macOS ≥ 10.7.

import AVFoundation

/// The single capture seam.  All camera I/O flows through this protocol.
///
/// Thread-safety: callers are responsible for synchronising access; in
/// practice this is driven from `CameraSessionViewModel` on the main actor.
public protocol CameraCapturing: AnyObject {

    /// The preview layer that renders the live camera feed.
    ///
    /// Available on macOS (AVFoundation, 10.7+) — `MockCameraService` returns
    /// a plain `AVCaptureVideoPreviewLayer()` so the seam compiles on all
    /// platforms under `swift test` (A-2).
    var previewLayer: AVCaptureVideoPreviewLayer { get }

    /// Requests the user's camera permission.
    ///
    /// - Returns: `true` if permission was granted, `false` otherwise.
    func requestPermission() async -> Bool

    /// Configures and starts the capture session so the preview layer is live.
    ///
    /// Throws if the capture session cannot be started (e.g. hardware
    /// unavailable).
    func startPreview() throws

    /// Begins recording a `.mov` file to `url`.
    ///
    /// - Parameter url: The file URL at which the recording will be written.
    ///   The caller is responsible for ensuring the parent directory exists
    ///   (see `LocalVideoStore.videoURL(for:)`).
    func startRecording(to url: URL) throws

    /// Stops an in-progress recording and waits for the file to be finalised.
    func stopRecording() async throws

    /// Tears down the capture session (balances `startPreview()`).
    func stopPreview()
}

/// CameraService — the concrete AVFoundation implementation of `CameraCapturing`.
///
/// Entirely wrapped in `#if !os(macOS)` (AC25): this file is excluded from the
/// macOS `swift test` build; only compiled when targeting iOS (or another
/// non-macOS Apple platform).
///
/// Build-only: correctness is verified at build time in Task 10 (`xcodebuild
/// build`).  No unit tests exercise this file; `MockCameraService` is the
/// test stand-in.

#if !os(macOS)

import AVFoundation
import Foundation

/// Concrete camera service backed by `AVCaptureSession` + `AVCaptureMovieFileOutput`.
///
/// Lifecycle:
/// 1. Call `requestPermission()` → `startPreview()` to bring the session live.
/// 2. Call `startRecording(to:)` to begin writing a `.mov` file.
/// 3. Call `stopRecording()` to finalise the file (awaits the delegate callback).
/// 4. Call `stopPreview()` to tear down the session.
///
/// Thread-safety: session configuration runs on a dedicated background queue;
/// `stopRecording()` bridges the AVFoundation delegate callback to `async/await`
/// via a checked continuation.
public final class CameraService: NSObject, CameraCapturing {

    // MARK: - Private state

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.tennisshottracker.CameraService.session")
    private let movieOutput = AVCaptureMovieFileOutput()

    /// Continuation used to bridge `fileOutput(_:didFinishRecordingTo:...)`
    /// back to the awaiting `stopRecording()` caller.
    private var stopRecordingContinuation: CheckedContinuation<Void, Error>?

    // MARK: - CameraCapturing

    /// The preview layer backed by the live capture session.
    public lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    /// Requests camera permission via `AVCaptureDevice.requestAccess`.
    public func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Configures the capture session and starts running it.
    ///
    /// - Throws: `CameraServiceError.deviceUnavailable` if no back-facing
    ///   video device is available, or if input/output cannot be added to
    ///   the session.
    public func startPreview() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back)
        else { throw CameraServiceError.deviceUnavailable }

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw CameraServiceError.sessionConfigurationFailed
        }
        session.addInput(input)

        guard session.canAddOutput(movieOutput) else {
            throw CameraServiceError.sessionConfigurationFailed
        }
        session.addOutput(movieOutput)

        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    /// Begins recording a `.mov` file to `url`.
    ///
    /// - Throws: `CameraServiceError.notRunning` if the session is not running,
    ///   or `CameraServiceError.alreadyRecording` if a recording is in progress.
    public func startRecording(to url: URL) throws {
        guard session.isRunning else { throw CameraServiceError.notRunning }
        guard !movieOutput.isRecording else { throw CameraServiceError.alreadyRecording }
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    /// Stops the current recording and waits for the file to be finalised.
    ///
    /// Bridges the `AVCaptureFileOutputRecordingDelegate` callback via a
    /// `CheckedContinuation`.  The continuation is fulfilled (or thrown into)
    /// in `fileOutput(_:didFinishRecordingTo:...)`.
    public func stopRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopRecordingContinuation = continuation
            movieOutput.stopRecording()
        }
    }

    /// Stops the capture session and releases the session queue.
    public func stopPreview() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraService: AVCaptureFileOutputRecordingDelegate {

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let continuation = stopRecordingContinuation
        stopRecordingContinuation = nil

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

// MARK: - Errors

/// Errors thrown by `CameraService`.
public enum CameraServiceError: LocalizedError {
    case deviceUnavailable
    case sessionConfigurationFailed
    case notRunning
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:        return "No back-facing camera available."
        case .sessionConfigurationFailed: return "Capture session could not be configured."
        case .notRunning:               return "Capture session is not running."
        case .alreadyRecording:         return "A recording is already in progress."
        }
    }
}

#endif // !os(macOS)

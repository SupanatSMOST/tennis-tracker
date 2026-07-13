/// MockCameraService — in-Sources stub for `CameraCapturing`.
///
/// Lives in `Sources/TennisCore/Camera/`, NOT in `Tests/`, so that it is
/// available to `CameraSessionViewModel` tests AND to SwiftUI previews
/// (mirrors the `InMemoryTokenStore` pattern from `Auth/TokenStore.swift`).
///
/// Compile target: all platforms (macOS + iOS), so `swift test` on macOS can
/// instantiate it directly (A-2 gate / FR-C3).

import AVFoundation
import Foundation

/// A fully configurable in-memory stub for `CameraCapturing`.
///
/// All I/O operations are synchronous no-ops except `startRecording(to:)`,
/// which writes an empty file at the given URL so callers can observe the
/// side effect (`LocalVideoStore.exists(for:)` returns `true` after recording).
///
/// **Spies** expose call history for XCTest assertions (AC19/AC20):
/// ```swift
/// XCTAssertEqual(mock.startRecordingCalledWith, expectedURL)
/// XCTAssertTrue(mock.stopRecordingCalled)
/// ```
public final class MockCameraService: CameraCapturing {

    // MARK: - Configuration

    /// Return value for `requestPermission()`.  Set to `false` to simulate
    /// a denied permission in tests.
    public var permissionResult: Bool = true

    // MARK: - Spies

    /// The URL passed to the most recent `startRecording(to:)` call, or `nil`
    /// if the method has not yet been called.
    public private(set) var startRecordingCalledWith: URL?

    /// `true` after `stopRecording()` has been called at least once.
    public private(set) var stopRecordingCalled: Bool = false

    /// `true` after `startPreview()` has been called at least once.
    public private(set) var startPreviewCalled: Bool = false

    /// `true` after `stopPreview()` has been called at least once.
    public private(set) var stopPreviewCalled: Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - CameraCapturing

    /// Returns a plain, unattached `AVCaptureVideoPreviewLayer` (no session).
    ///
    /// Sufficient for the VM to hold a reference; the preview layer is not
    /// rendered in tests.
    public var previewLayer: AVCaptureVideoPreviewLayer {
        AVCaptureVideoPreviewLayer()
    }

    /// Returns the configured `permissionResult` stub value.
    public func requestPermission() async -> Bool {
        permissionResult
    }

    /// Records the call; no actual session is started.
    public func startPreview() throws {
        startPreviewCalled = true
    }

    /// Records the URL spy and writes an **empty file** at `url`.
    ///
    /// Writing an empty file lets tests confirm `LocalVideoStore.exists(for:)`
    /// returns `true` after `startRecording` — without needing a real camera.
    ///
    /// - Throws: A `CocoaError` if the parent directory does not exist and
    ///   the write fails.  In normal use `LocalVideoStore.videoURL(for:)`
    ///   ensures the directory exists before this is called.
    public func startRecording(to url: URL) throws {
        startRecordingCalledWith = url
        // ponytail: writing empty Data is intentional — the spy needs a real
        // file on disk so LocalVideoStore.exists() returns true (AC19).
        // Upgrade path: if tests need a non-empty mov, replace with a stub
        // mov fixture.  Not required by any current AC.
        try Data().write(to: url)
    }

    /// Marks `stopRecordingCalled = true`; resolves immediately.
    public func stopRecording() async throws {
        stopRecordingCalled = true
    }

    /// Records the call; no actual session is torn down.
    public func stopPreview() {
        stopPreviewCalled = true
    }
}

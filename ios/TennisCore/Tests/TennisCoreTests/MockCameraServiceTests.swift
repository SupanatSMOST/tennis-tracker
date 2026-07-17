/// MockCameraServiceTests — Task 4 optional tests (plan §Task 4 / AC25 + A-2).
///
/// Proves:
/// 1. `requestPermission()` returns the configured `permissionResult` stub.
/// 2. `startRecording(to:)` writes an empty file at the given URL, and the
///    `startRecordingCalledWith` spy captures it.

import XCTest
@testable import TennisCore

final class MockCameraServiceTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// `requestPermission()` returns the value configured on `permissionResult`.
    func testPermissionStubReturnsFalseWhenConfigured() async {
        let mock = MockCameraService()
        mock.permissionResult = false
        let result = await mock.requestPermission()
        XCTAssertFalse(result, "requestPermission() must return the configured stub value")
    }

    /// `startRecording(to:)` creates a file at the given URL and records the spy.
    func testStartRecordingWritesEmptyFile() throws {
        let mock = MockCameraService()
        let url = tempDir.appendingPathComponent("test-match.mov")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "precondition: file must not exist before startRecording")

        try mock.startRecording(to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "startRecording(to:) must write a file at the given URL (AC19 spy)")
        XCTAssertEqual(mock.startRecordingCalledWith, url,
                       "startRecordingCalledWith spy must capture the URL")
    }
}

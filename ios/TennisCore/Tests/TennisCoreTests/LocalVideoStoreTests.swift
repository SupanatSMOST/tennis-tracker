/// LocalVideoStoreTests — hermetic tests for Task 3 (LocalVideoStore).
///
/// Each test injects a unique temp baseDirectory and removes it in tearDown.
/// No writes ever reach the real ~/Documents directory.
///
/// Coverage: AC11 (videoURL path construction), AC12 (exists/delete lifecycle).

import XCTest
@testable import TennisCore

final class LocalVideoStoreTests: XCTestCase {

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

    private func makeStore() -> LocalVideoStore {
        LocalVideoStore(baseDirectory: baseDir)
    }

    // MARK: - AC11: videoURL path construction

    /// AC11: videoURL(for:) returns a file URL whose path ends in videos/{matchId}.mov,
    /// under the injected base directory — not the real ~/Documents.
    func testAC11_videoURL_isFileURLWithCorrectPathUnderBaseDirectory() {
        let store = makeStore()
        let matchId = "match-ac11"

        let url = store.videoURL(for: matchId)

        XCTAssertTrue(url.isFileURL, "AC11: videoURL must be a file URL")
        XCTAssertTrue(
            url.path.hasSuffix("videos/\(matchId).mov"),
            "AC11: path must end in videos/\(matchId).mov — got \(url.path)"
        )
        XCTAssertTrue(
            url.path.hasPrefix(baseDir.path),
            "AC11: path must be under the injected baseDirectory \(baseDir.path) — got \(url.path)"
        )
    }

    // MARK: - AC12: exists/delete lifecycle

    /// AC12 part 1: exists false before write, true after write, false after delete.
    func testAC12_exists_togglesTrueAfterWriteAndFalseAfterDelete() throws {
        let store = makeStore()
        let matchId = "match-ac12-lifecycle"

        // Pre-condition: no file yet.
        XCTAssertFalse(store.exists(for: matchId), "AC12: exists must be false before any write")

        // videoURL(for:) creates the videos/ directory; write an empty file there.
        let url = store.videoURL(for: matchId)
        try Data().write(to: url)

        XCTAssertTrue(store.exists(for: matchId), "AC12: exists must be true after writing a file at videoURL")

        // Delete and confirm it is gone.
        try store.delete(for: matchId)

        XCTAssertFalse(store.exists(for: matchId), "AC12: exists must be false after delete")
    }

    /// AC12 part 2: delete on a matchId that was never created must not throw.
    func testAC12_deleteOnAbsentFile_doesNotThrow() {
        let store = makeStore()
        // This matchId has never had a file written — delete must be a no-op.
        XCTAssertNoThrow(
            try store.delete(for: "never-created-match-ac12"),
            "AC12: delete on a nonexistent file must not throw"
        )
    }
}

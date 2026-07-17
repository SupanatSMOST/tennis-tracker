/// LocalVideoStore — resolves and manages the on-device `.mov` file for a match.
///
/// Path layout: `<baseDirectory ?? Documents>/videos/{matchId}.mov`
///
/// The `videos/` directory is created by `videoURL(for:)` before the caller
/// (i.e. the camera) writes to the URL.  `exists` and `delete` are side-effect-
/// free with respect to directory creation — they operate on the path directly.

import Foundation

/// File-backed store for per-match video URLs.
///
/// Thread-safety: not thread-safe — each caller owns its own instance and
/// must synchronise externally if needed.  In practice this is called from
/// a single VM on the main actor, so no lock is required.
public struct LocalVideoStore {

    private let baseDirectory: URL

    // MARK: Init

    /// - Parameter baseDirectory: Override the base directory for test
    ///   isolation (plan §2.1.3 / A-4).  Defaults to the app's `Documents`
    ///   directory.
    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            self.baseDirectory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
    }

    // MARK: Private helpers

    private var videosDir: URL {
        baseDirectory.appendingPathComponent("videos", isDirectory: true)
    }

    /// Returns the file URL for `matchId` **without** creating any directory.
    ///
    /// Used internally by `exists` and `delete`, which must be side-effect-free.
    private func fileURL(for matchId: String) -> URL {
        videosDir.appendingPathComponent("\(matchId).mov")
    }

    // MARK: Public API

    /// Returns the URL at which the video for `matchId` should be written,
    /// creating the `videos/` directory if it does not yet exist.
    ///
    /// Non-throwing by design (pinned signature).  Directory creation failures
    /// are swallowed with `try?` — if the directory cannot be created the
    /// subsequent camera write will surface the error.
    ///
    /// ponytail: directory creation in a non-throwing getter is intentional;
    /// the AVFoundation camera API writes directly to this URL (no save() hook
    /// exists), so this is the only pre-write opportunity.  Upgrade path: if
    /// the store ever gains a save() entry point, move creation there and make
    /// videoURL() a pure path computation.
    public func videoURL(for matchId: String) -> URL {
        // ponytail: try? is deliberate — signature is pinned non-throwing (plan
        // §2.1.3); errors are surfaced by the camera write that follows.
        try? FileManager.default.createDirectory(
            at: videosDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return fileURL(for: matchId)
    }

    /// Returns `true` if a video file exists for `matchId` (AC12).
    public func exists(for matchId: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: matchId).path)
    }

    /// Removes the video file for `matchId`.
    ///
    /// No-op if the file is absent (AC12).
    public func delete(for matchId: String) throws {
        let url = fileURL(for: matchId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

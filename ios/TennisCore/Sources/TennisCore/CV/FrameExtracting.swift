/// FrameExtracting — protocol for the frame-extraction stage of the CV pipeline.
///
/// Concrete implementation (`FrameExtractor`) is AVFoundation-backed and
/// `#if !os(macOS)`-guarded (Task 7 — build-only).  On macOS the protocol
/// compiles via CoreVideo, which is available on macOS.
///
/// `index` semantics (A-6): the ORIGINAL-video frame number, not the position
/// in the returned subsequence.  For stride 2 over a 10-frame video the
/// returned sequence has indices 0, 2, 4, 6, 8, each pointing back to its
/// absolute frame in the source file.

import CoreVideo

/// Extracts a strided sequence of pixel buffers from a video file.
public protocol FrameExtracting {

    /// Extracts frames from `url`, taking every `stride`-th frame.
    ///
    /// - Parameters:
    ///   - url: Local URL of the video file (`.mov` in production).
    ///   - stride: Step size — `1` processes every frame (OQ-3 default).
    /// - Returns: Tuples of (original-video `index`, `pixelBuffer`), in
    ///   ascending index order.  `index` is the ORIGINAL-video frame number
    ///   (stride applied — A-6), not the position in the result array.
    /// - Throws: Any I/O or decoding error encountered while reading the file.
    func extractFrames(
        from url: URL,
        every stride: Int
    ) async throws -> [(index: Int, pixelBuffer: CVPixelBuffer)]
}

/// FrameExtractor — AVFoundation-backed concrete implementation of `FrameExtracting`.
///
/// Entirely wrapped in `#if !os(macOS)` (mirrors `CameraService`): this file is
/// excluded from the macOS `swift test` build.  Only compiled when targeting iOS
/// or another non-macOS Apple platform.
///
/// Build-only: correctness is verified at build time in Task 11 (`xcodebuild build`).
/// No unit tests exercise this file; `MockFrameExtractor` is the test stand-in.

#if !os(macOS)

import AVFoundation
import CoreVideo

/// Extracts a strided sequence of pixel buffers from a `.mov` video file using
/// `AVAssetReader` for sequential frame access.
///
/// `index` semantics (A-6): each tuple's `index` is the ORIGINAL-video frame
/// number, not the position in the returned subsequence.  For stride 2 over a
/// 10-frame video the returned sequence carries indices 0, 2, 4, 6, 8.
public final class FrameExtractor: FrameExtracting {

    public init() {}

    /// Extracts frames from the video at `url`, returning every `stride`-th frame.
    ///
    /// - Parameters:
    ///   - url: Local URL of the video file (`.mov` in production).
    ///   - stride: Step size — `1` processes every frame (OQ-3 default).
    /// - Returns: Tuples of (original-video `index`, `pixelBuffer`), ascending.
    /// - Throws: `FrameExtractorError.noVideoTrack` when the asset has no video
    ///   track; `FrameExtractorError.cannotStartReading` if the reader fails to
    ///   start; `FrameExtractorError.readFailed` if a mid-read failure occurs.
    public func extractFrames(
        from url: URL,
        every stride: Int
    ) async throws -> [(index: Int, pixelBuffer: CVPixelBuffer)] {

        let asset = AVURLAsset(url: url)

        // Load the video track asynchronously (avoids deprecated sync API on iOS 17+).
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw FrameExtractorError.noVideoTrack
        }

        // Build the reader with BGRA output — a common format that downstream
        // CoreML models can ingest without additional conversion.
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        // alwaysCopiesSampleData defaults to true — buffers are independent copies
        // that are safe to retain across the full results array.

        guard reader.canAdd(output) else {
            throw FrameExtractorError.cannotStartReading
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? FrameExtractorError.cannotStartReading
        }

        var results: [(index: Int, pixelBuffer: CVPixelBuffer)] = []
        var frameIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let currentIndex = frameIndex
            frameIndex += 1

            guard currentIndex % stride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            results.append((index: currentIndex, pixelBuffer: pixelBuffer))
        }

        // Distinguish a clean end-of-stream from a mid-read failure.
        guard reader.status == .completed else {
            throw reader.error ?? FrameExtractorError.readFailed
        }

        return results
    }
}

// MARK: - Errors

/// Errors thrown by `FrameExtractor`.
public enum FrameExtractorError: LocalizedError {
    case noVideoTrack
    case cannotStartReading
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The asset contains no video track."
        case .cannotStartReading:
            return "AVAssetReader could not start reading the asset."
        case .readFailed:
            return "A failure occurred while reading frames from the asset."
        }
    }
}

#endif // !os(macOS)

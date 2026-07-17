/// BallTrackerInference — CoreML-backed concrete implementation of `BallTracking`.
///
/// Entirely wrapped in `#if !os(macOS)` so it is excluded from the macOS
/// `swift test` build (the hermetic gate — AC24, plan §2).  Only compiled when
/// targeting iOS (or another non-macOS Apple platform).
///
/// Build-only: correctness is validated manually on-device.  No unit tests
/// exercise this file (model file absent in CI — plan §2 / Task 8).
///
/// ## Phase-0 post-processing (deliberately simplified)
/// The Phase-0 spike (`ball_detector.py`) uses argmax → ×255-wrap → uint8 →
/// threshold@127 → HoughCircles → temporal prev-frame gating → ×2.
///
/// This implementation uses: argmax → threshold@128 → centroid → ×2.
///
/// Deliberate divergences (flagged, not bugs):
///   (a) **Centroid, not HoughCircles.** CoreML/Swift has no built-in Hough-
///       circle detector.  The centroid (mean coordinate of above-threshold
///       pixels) is functionally equivalent for a small, compact ball blob.
///   (b) **No temporal prev-frame distance gating.**  Outlier rejection is
///       deferred to a future refinement pass.
///   (c) **Threshold T = 128 (direct, not via ×255 uint8 wrap).**  Phase-0
///       applies `*=255` then casts to uint8 which can wrap for argmax values
///       > 255 (impossible — argmax ∈ [0,255], no wrap), then thresholds at
///       127.  Equivalently, any argmax value ≥ 128 indicates a detected ball.
///       T=128 is a deliberate, documented judgment call.
///
/// ## Input pixel buffer assumption
/// `track(frames:)` expects BGRA `CVPixelBuffer`s, as emitted by the
/// AVFoundation `FrameExtractor` (Task 7).  The first three channels (B, G, R)
/// are extracted and alpha is dropped.  This is a cross-agent coupling
/// precondition; a mismatched format (e.g. RGBA) will silently corrupt channels.
///
/// ## Output coordinate space
/// Returns `(x, y)` in **landscape 1280×720** pixel space (`×2` from the
/// 640×360 model output — OQ-1 RESOLVED, plan §5.1).

#if !os(macOS)

import CoreML
import CoreVideo
import Foundation

/// CoreML-backed ball tracker.  Loads `BallTracker.mlpackage` at runtime via
/// `MLModel(contentsOf:)` — **not** Xcode auto-generated model classes — so the
/// file can be absent at compile/test time without breaking the build (plan §3.4).
public final class BallTrackerInference: BallTracking {

    // MARK: - Constants

    /// Model input spatial dimensions (H=360, W=640).
    private let modelHeight = 360
    private let modelWidth  = 640

    /// The argmax index threshold above which a pixel is considered a ball hit.
    /// Phase-0 equivalent: threshold@127 on a `uint8` map; argmax ∈ [0,255]
    /// so values ≥ 128 indicate confident detection.
    private let detectionThreshold: Float = 128.0

    // MARK: - Private state

    private let model: MLModel
    private let inputName:  String
    private let outputName: String

    // MARK: - Init

    /// Loads the ball-tracking model from `modelURL`.
    ///
    /// Throws when the model file cannot be loaded (expected in CI — plan §2).
    public init(modelURL: URL) throws {
        model = try MLModel(contentsOf: modelURL)

        // Discover feature names at runtime — coremltools naming is not stable.
        guard let inKey = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw BallTrackerError.modelInputNotFound
        }
        guard let outKey = model.modelDescription.outputDescriptionsByName.keys.first else {
            throw BallTrackerError.modelOutputNotFound
        }
        inputName  = inKey
        outputName = outKey
    }

    /// Convenience initialiser that resolves `BallTracker.mlpackage` from
    /// `Bundle.main`'s `Resources/ML/` folder.
    ///
    /// Throws when the bundle resource or the model cannot be loaded.
    public convenience init() throws {
        guard let url = Bundle.main.url(forResource: "BallTracker",
                                        withExtension: "mlpackage") ??
                        Bundle.main.url(forResource: "BallTracker",
                                        withExtension: "mlmodelc")
        else {
            throw BallTrackerError.modelNotFoundInBundle
        }
        try self.init(modelURL: url)
    }

    // MARK: - BallTracking

    /// Runs TrackNet over `frames` and returns one `(x, y)?` per frame in
    /// **landscape 1280×720** pixel space.
    ///
    /// The model requires triplets of 3 consecutive frames (current, prev,
    /// prev-prev) stacked channel-wise → input shape `(1,9,360,640)` float32
    /// BGR, normalised [0,1].  Frames 0 and 1 cannot form a full triplet and
    /// always return `nil`.  Frame `i` (i ≥ 2) uses the triplet `[i, i-1, i-2]`.
    ///
    /// Post-processing per frame:
    ///   1. argmax over 256 channels → intensity map (1,360,640).
    ///   2. Threshold at 128 → ball-blob mask.
    ///   3. Centroid of blob pixels → (cx, cy) in [0,360)×[0,640) space.
    ///   4. Scale ×2 → (x, y) in [0,720)×[0,1280) landscape space (OQ-1).
    public func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?] {
        guard !frames.isEmpty else { return [] }

        var results: [(x: Float, y: Float)?] = Array(repeating: nil, count: frames.count)

        // Frames 0 and 1 cannot form a triplet → remain nil (matches Phase-0).
        for i in 2 ..< frames.count {
            let current  = frames[i]
            let prev     = frames[i - 1]
            let prevPrev = frames[i - 2]

            let input = try buildInput(current: current, prev: prev, prevPrev: prevPrev)
            let featureProvider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: input)]
            )
            let output = try await model.prediction(from: featureProvider)

            guard let heatmap = output.featureValue(for: outputName)?.multiArrayValue else {
                continue // no output for this frame → nil
            }

            results[i] = postprocess(heatmap: heatmap)
        }

        return results
    }

    // MARK: - Private helpers

    /// Builds the `(1,9,360,640)` float32 input by resizing three frames to
    /// 360×640 and stacking them channel-wise in BGR order (current, prev,
    /// prev-prev — matching Phase-0's `np.concatenate((img, img_prev,
    /// img_preprev), axis=2)` with `/255.0` normalisation).
    private func buildInput(
        current: CVPixelBuffer,
        prev: CVPixelBuffer,
        prevPrev: CVPixelBuffer
    ) throws -> MLMultiArray {
        // Shape: [1, 9, 360, 640]
        let array = try MLMultiArray(
            shape: [1, 9, modelHeight, modelWidth] as [NSNumber],
            dataType: .float32
        )

        // Write the three frames into the array.
        // Channel slots: current=[0,1,2], prev=[3,4,5], prevPrev=[6,7,8]
        try writeFrame(current,  into: array, channelOffset: 0)
        try writeFrame(prev,     into: array, channelOffset: 3)
        try writeFrame(prevPrev, into: array, channelOffset: 6)

        return array
    }

    /// Copies one frame's B, G, R channels (normalised to [0,1]) into `array`
    /// starting at `channelOffset`.
    ///
    /// Assumes **BGRA** pixel format (CVPixelBufferLockFlags read-only).
    /// A mismatched format silently corrupts channels — documented precondition.
    private func writeFrame(
        _ buffer: CVPixelBuffer,
        into array: MLMultiArray,
        channelOffset: Int
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw BallTrackerError.pixelBufferLockFailed
        }

        let srcWidth  = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Stride layout for array shape [1, 9, H, W]:
        //   array index = 0*s0 + ch*s1 + row*s2 + col*s3
        //   s0 = 9*H*W, s1 = H*W, s2 = W, s3 = 1
        let s1 = modelHeight * modelWidth  // H*W
        let s2 = modelWidth                // W

        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)

        // Scale factors for nearest-neighbour resize from srcHeight×srcWidth → H×W.
        let scaleH = Float(srcHeight) / Float(modelHeight)
        let scaleW = Float(srcWidth)  / Float(modelWidth)

        for row in 0 ..< modelHeight {
            let srcRow = Int(Float(row) * scaleH + 0.5)
                .clamped(to: 0 ..< srcHeight)
            let rowBase = srcRow * bytesPerRow

            for col in 0 ..< modelWidth {
                let srcCol = Int(Float(col) * scaleW + 0.5)
                    .clamped(to: 0 ..< srcWidth)
                let pixelOffset = rowBase + srcCol * 4  // 4 bytes per BGRA pixel

                // BGRA layout: byte[0]=B, [1]=G, [2]=R, [3]=A
                let b = Float(bytes[pixelOffset])     / 255.0
                let g = Float(bytes[pixelOffset + 1]) / 255.0
                let r = Float(bytes[pixelOffset + 2]) / 255.0

                // Write B, G, R into consecutive channels.
                let base0 = (channelOffset + 0) * s1 + row * s2 + col
                let base1 = (channelOffset + 1) * s1 + row * s2 + col
                let base2 = (channelOffset + 2) * s1 + row * s2 + col

                ptr[base0] = b
                ptr[base1] = g
                ptr[base2] = r
            }
        }
    }

    /// Applies `argmax → threshold → centroid → ×2` to a `(1,256,360,640)` heatmap.
    ///
    /// Returns `nil` when no above-threshold pixel is found (no ball in frame).
    private func postprocess(heatmap: MLMultiArray) -> (x: Float, y: Float)? {
        // Expected shape: [1, 256, H, W]
        // Stride layout: s0=256*H*W, s1=H*W, s2=W, s3=1
        let nChannels = 256
        let H = modelHeight
        let W = modelWidth
        let s1 = H * W
        let s2 = W

        let ptr = heatmap.dataPointer.assumingMemoryBound(to: Float.self)

        // Step 1: argmax over 256 channels → intensity map (H×W).
        // Re-use a flat buffer to avoid per-pixel allocation.
        var blobSumX: Float = 0
        var blobSumY: Float = 0
        var blobCount: Int  = 0

        for row in 0 ..< H {
            for col in 0 ..< W {
                // Find argmax channel for this (row, col).
                var maxVal: Float = -.infinity
                var maxIdx: Float = 0
                for ch in 0 ..< nChannels {
                    let v = ptr[ch * s1 + row * s2 + col]
                    if v > maxVal {
                        maxVal = v
                        maxIdx = Float(ch)
                    }
                }

                // Step 2: threshold — argmax index acts as intensity (0–255).
                if maxIdx >= detectionThreshold {
                    // Step 3: accumulate blob pixels for centroid.
                    blobSumX += Float(col)
                    blobSumY += Float(row)
                    blobCount += 1
                }
            }
        }

        guard blobCount > 0 else { return nil }

        // Step 4: centroid → scale ×2 → landscape 1280×720.
        let cx = (blobSumX / Float(blobCount)) * 2.0
        let cy = (blobSumY / Float(blobCount)) * 2.0
        return (x: cx, y: cy)
    }
}

// MARK: - Errors

/// Errors thrown by `BallTrackerInference`.
public enum BallTrackerError: LocalizedError {
    case modelNotFoundInBundle
    case modelInputNotFound
    case modelOutputNotFound
    case pixelBufferLockFailed

    public var errorDescription: String? {
        switch self {
        case .modelNotFoundInBundle:
            return "BallTracker.mlpackage / .mlmodelc not found in Bundle.main."
        case .modelInputNotFound:
            return "The CoreML model has no input feature description."
        case .modelOutputNotFound:
            return "The CoreML model has no output feature description."
        case .pixelBufferLockFailed:
            return "Could not lock CVPixelBuffer base address for reading."
        }
    }
}

#endif // !os(macOS)

// MARK: - ClosedRange clamping helper (file-private)
// Avoids importing any extra framework just for clamping an Int.

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}

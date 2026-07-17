/// BallTrackerInference — CoreML-backed concrete implementation of `BallTracking`.
///
/// Entirely wrapped in `#if !os(macOS)` so it is excluded from the macOS
/// `swift test` build (the hermetic gate — AC24, plan §2).  Only compiled when
/// targeting iOS (or another non-macOS Apple platform).
///
/// Build-only: correctness is validated manually on-device.  No unit tests
/// exercise this file (model file absent in CI — plan §2 / Task 8).
///
/// ## Phase-0 post-processing (deliberately NOT byte-equivalent)
/// The Phase-0 spike (`ball_detector.py`) uses:
///   argmax → ×255 (in-place on float) → cast uint8 → threshold@127 →
///   HoughCircles → temporal prev-frame distance gating → ×2.
///
/// This implementation uses: argmax → threshold@128 → centroid → ×2.
///
/// Deliberate divergences (flagged, not bugs):
///   (a) **Centroid, not HoughCircles.**  CoreML/Swift has no built-in
///       Hough-circle detector.  The centroid (mean coordinate of above-
///       threshold pixels) is equivalent for a compact ball blob.
///   (b) **No temporal prev-frame distance gating.**  Outlier rejection is
///       deferred to a future refinement pass.
///   (c) **Threshold T = 128 (clean intensity threshold, not via ×255/uint8).**
///       Phase-0's `feature_map *= 255` followed by `astype(uint8)` produces
///       chaotic wrapping behaviour (e.g. argmax=255→uint8 1, argmax=200→uint8
///       56) that makes the effective threshold unpredictable.  Using argmax
///       index directly as intensity and thresholding at 128 is the sane,
///       intentional choice.  This is **not** byte-equivalent to Phase-0.
///   (d) **Nearest-neighbour resize** (Phase-0 uses `cv2.resize` bilinear).
///
/// ## Input pixel buffer assumption
/// `track(frames:)` expects **BGRA** `CVPixelBuffer`s (kCVPixelFormatType_32BGRA),
/// as emitted by the AVFoundation `FrameExtractor` (Task 7 — cross-agent
/// precondition).  B, G, R are extracted; alpha is dropped.  A mismatched format
/// (e.g. RGBA) will silently corrupt channels.
///
/// ## Output tensor assumption
/// The model is expected to emit a `float32` output MultiArray.  If coremltools
/// converts to `float16`, `postprocess` will detect it at runtime and throw
/// `BallTrackerError.unsupportedOutputDataType`.  Force `compute_precision=Float`
/// in `convert_models.py` to guarantee float32 output.
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

    /// Number of output channels (TrackNet head output).
    private let modelChannels = 256

    /// Argmax index threshold: any argmax value ≥ 128 is treated as a
    /// confident ball detection.  See header for rationale vs Phase-0.
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

    /// Convenience initialiser that resolves `BallTracker.mlpackage` (or the
    /// compiled `.mlmodelc`) from `Bundle.main`'s `Resources/ML/` folder.
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
    ///   1. argmax over 256 channels → intensity map (H×W).
    ///   2. Threshold at 128 → ball-blob mask.
    ///   3. Centroid of blob pixels → (cx, cy) in [0,360)×[0,640) space.
    ///   4. Scale ×2 → (x, y) in landscape 1280×720 space (OQ-1).
    public func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?] {
        guard !frames.isEmpty else { return [] }

        var results: [(x: Float, y: Float)?] = Array(repeating: nil, count: frames.count)

        // Frames 0 and 1 cannot form a triplet → remain nil (matches Phase-0 behaviour).
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

            results[i] = try postprocess(heatmap: heatmap)
        }

        return results
    }

    // MARK: - Private helpers

    /// Builds the `(1,9,360,640)` float32 input by resizing three frames to
    /// 360×640 and stacking them channel-wise in BGR order (current, prev,
    /// prev-prev — matching Phase-0's `np.concatenate((img, img_prev,
    /// img_preprev), axis=2)` with `/255.0` normalisation).
    ///
    /// Resize method: nearest-neighbour (Phase-0 uses bilinear — minor fidelity
    /// difference, documented in file header).
    private func buildInput(
        current: CVPixelBuffer,
        prev: CVPixelBuffer,
        prevPrev: CVPixelBuffer
    ) throws -> MLMultiArray {
        // Shape: [1, 9, H, W]; strides are densely packed (we created this array).
        let array = try MLMultiArray(
            shape: [1, 9, modelHeight, modelWidth] as [NSNumber],
            dataType: .float32
        )

        // Channel slots: current=[0,1,2], prev=[3,4,5], prevPrev=[6,7,8]
        try writeFrame(current,  into: array, channelOffset: 0)
        try writeFrame(prev,     into: array, channelOffset: 3)
        try writeFrame(prevPrev, into: array, channelOffset: 6)

        return array
    }

    /// Copies one frame's B, G, R channels (normalised to [0,1]) into `array`
    /// starting at `channelOffset`.
    ///
    /// Assumes **BGRA** pixel format (kCVPixelFormatType_32BGRA).
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

        let srcWidth    = CVPixelBufferGetWidth(buffer)
        let srcHeight   = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes       = base.assumingMemoryBound(to: UInt8.self)

        // We created this array above so strides are densely packed:
        // shape [1, 9, H, W] → strides [9·H·W, H·W, W, 1].
        let s1 = modelHeight * modelWidth   // stride over channel dim
        let s2 = modelWidth                 // stride over row dim

        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)

        // Scale factors for nearest-neighbour resize srcH×srcW → modelH×modelW.
        let scaleH = Float(srcHeight) / Float(modelHeight)
        let scaleW = Float(srcWidth)  / Float(modelWidth)

        for row in 0 ..< modelHeight {
            let srcRow = Int(Float(row) * scaleH + 0.5).clamped(to: 0 ..< srcHeight)
            let rowBase = srcRow * bytesPerRow

            for col in 0 ..< modelWidth {
                let srcCol  = Int(Float(col) * scaleW + 0.5).clamped(to: 0 ..< srcWidth)
                let pxOff   = rowBase + srcCol * 4  // 4 bytes per BGRA pixel

                // BGRA layout: byte[0]=B, [1]=G, [2]=R, [3]=A
                let b = Float(bytes[pxOff])     / 255.0
                let g = Float(bytes[pxOff + 1]) / 255.0
                let r = Float(bytes[pxOff + 2]) / 255.0

                let idx0 = (channelOffset + 0) * s1 + row * s2 + col
                let idx1 = (channelOffset + 1) * s1 + row * s2 + col
                let idx2 = (channelOffset + 2) * s1 + row * s2 + col

                ptr[idx0] = b
                ptr[idx1] = g
                ptr[idx2] = r
            }
        }
    }

    /// Applies `argmax → threshold → centroid → ×2` to a `(1,256,H,W)` heatmap.
    ///
    /// Reads actual strides from `heatmap` to handle non-contiguous output
    /// layouts that some coremltools conversions produce.  Throws
    /// `BallTrackerError.unsupportedOutputDataType` if the model emitted a
    /// non-float32 array (e.g. float16 — fix by setting
    /// `compute_precision=Float` in `convert_models.py`).
    ///
    /// Returns `nil` when no above-threshold pixel is found (no ball in frame).
    private func postprocess(heatmap: MLMultiArray) throws -> (x: Float, y: Float)? {
        // Guard float32 — coremltools can emit float16 and reinterpreting
        // float16 bytes as float32 produces silent garbage.
        guard heatmap.dataType == .float32 else {
            throw BallTrackerError.unsupportedOutputDataType(heatmap.dataType)
        }

        // Read actual shape and strides from the multiarray so we're robust
        // to non-contiguous (padded) output tensors.
        // Expected shape: [1, C, H, W] where C=256, H=360, W=640.
        let shape   = heatmap.shape.map { $0.intValue }
        let strides = heatmap.strides.map { $0.intValue }

        // Shape must be 4-dimensional; use defaults only when dims match expectations.
        guard shape.count == 4 else {
            throw BallTrackerError.unexpectedOutputShape(shape)
        }
        let nC  = shape[1]   // channels (expected 256)
        let nH  = shape[2]   // height   (expected 360)
        let nW  = shape[3]   // width    (expected 640)

        let s0  = strides[0] // stride along batch   (unused — batch=1)
        let s1  = strides[1] // stride along channel
        let s2  = strides[2] // stride along row
        let s3  = strides[3] // stride along col
        _ = s0               // suppress unused-variable warning

        let ptr = heatmap.dataPointer.assumingMemoryBound(to: Float.self)

        var blobSumX: Float = 0
        var blobSumY: Float = 0
        var blobCount: Int  = 0

        // argmax over nC channels at each (row, col) position.
        for row in 0 ..< nH {
            for col in 0 ..< nW {
                var maxIdx: Float = 0
                var maxVal: Float = -.infinity

                for ch in 0 ..< nC {
                    let v = ptr[ch * s1 + row * s2 + col * s3]
                    if v > maxVal {
                        maxVal = v
                        maxIdx = Float(ch)
                    }
                }

                // Threshold: argmax index treated as intensity (0–255).
                if maxIdx >= detectionThreshold {
                    blobSumX += Float(col)
                    blobSumY += Float(row)
                    blobCount += 1
                }
            }
        }

        guard blobCount > 0 else { return nil }

        // Centroid → ×2 → landscape 1280×720 (OQ-1).
        let cx = (blobSumX / Float(blobCount)) * 2.0
        let cy = (blobSumY / Float(blobCount)) * 2.0
        return (x: cx, y: cy)
    }

    // MARK: - Int clamping (inside guard so it does not leak to macOS build)

    // ponytail: private extension on Int lives inside #if !os(macOS) so it
    // is fully excluded from the macOS swift test build.
}

// MARK: - Errors

/// Errors thrown by `BallTrackerInference`.
public enum BallTrackerError: Error {
    case modelNotFoundInBundle
    case modelInputNotFound
    case modelOutputNotFound
    case pixelBufferLockFailed
    case unsupportedOutputDataType(MLMultiArrayDataType)
    case unexpectedOutputShape([Int])
}

// MARK: - Int range-clamping helper (iOS-only, stays inside the guard)

private extension Int {
    /// Clamps `self` to the half-open `range`, returning `range.lowerBound` when
    /// `self < range.lowerBound` and `range.upperBound - 1` when
    /// `self ≥ range.upperBound`.
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}

#endif // !os(macOS)

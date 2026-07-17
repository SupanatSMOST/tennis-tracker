/// BounceDetectorInference — CoreML-backed bounce detector.
///
/// Entirely wrapped in `#if !os(macOS)` — excluded from the macOS `swift test`
/// build (AC24). Build-only (Task 9); no swift tests (needs the model file).
///
/// Feature order is recovered byte-for-byte from the Phase-0 authority:
/// `bounce_detector.py → BounceDetector.prepare_features → colnames_x + colnames_y`
/// (TennisProject/bounce_detector.py, lines 39-48). See cv/README.md §5 for the
/// full documented order.

#if !os(macOS)

import CoreML
import Foundation

/// CoreML-backed implementation of `BounceDetecting`.
///
/// Loads `BounceDetector.mlmodel` at runtime via `MLModel(contentsOf:)` — no
/// Xcode-generated model classes (plan §3.4).  Feature construction matches the
/// Phase-0 CatBoost training pipeline exactly (OQ-2).
public final class BounceDetectorInference: BounceDetecting {

    // MARK: - Private state

    private let model: MLModel

    // MARK: - Init

    /// Loads the model from an explicit URL (primary initialiser).
    ///
    /// - Parameter modelURL: Path to `BounceDetector.mlmodel` (or `.mlmodelc`
    ///   after Xcode compilation into the app bundle).
    /// - Throws: `MLModelError` if the model cannot be loaded.
    public init(modelURL: URL) throws {
        model = try MLModel(contentsOf: modelURL)
    }

    /// Convenience initialiser: resolves `BounceDetector.mlmodel(c)` from
    /// `Bundle.main` and calls `init(modelURL:)`.
    ///
    /// Task 11's composition root calls `BounceDetectorInference()` with no
    /// arguments; this convenience init satisfies that call site while keeping
    /// the testable `init(modelURL:)` as the designated path.
    ///
    /// ponytail: The resource lookup tries "mlmodelc" (Xcode-compiled) first,
    /// then falls back to "mlmodel" (raw). Confirm against convert_models.py
    /// printed spec + Task 11 bundle path once AC25 is validated.
    public convenience init() throws {
        let url = Bundle.main.url(forResource: "BounceDetector", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "BounceDetector", withExtension: "mlmodel")
        guard let resolved = url else {
            throw BounceDetectorInferenceError.modelNotFound
        }
        try self.init(modelURL: resolved)
    }

    // MARK: - BounceDetecting

    /// Detects bounces from an indexed ball trajectory.
    ///
    /// For each **scoreable** frame (array position `n` where positions
    /// n-2, n-1, n, n+1, n+2 ALL have non-nil ball points), this method:
    /// 1. Builds the 12-column feature `MLMultiArray` in the exact Phase-0
    ///    column order (x-block then y-block, defined in cv/README.md §5).
    /// 2. Runs the CatBoost CoreML model and reads the predicted probability.
    /// 3. Applies threshold `> 0.45` (strict, matching `np.where(preds > threshold)`).
    /// 4. Applies `postprocess` consecutive-bounce collapse (Phase-0 faithful,
    ///    bounce_detector.py:88-96): collapses runs of consecutive compacted-index
    ///    above-threshold frames to a single bounce (keeps the highest-prob frame
    ///    in the run via predecessor-comparison, matching Phase-0 exactly).
    ///
    /// Frames near the ends (fewer than 2 neighbours on either side) and frames
    /// with any nil lag are skipped silently (not scored).
    ///
    /// Known Phase-0 fidelity gap (not ported — see cv/README.md §5):
    /// - `smooth_predictions` (cubic-spline gap extrapolation, bounce_detector.py:61-78):
    ///   requires scipy CubicSpline with no clean Swift equivalent; porting risks
    ///   silent numerical divergence. This is a known gap to be validated/closed
    ///   at the on-device Phase-0 numerical-parity gate (Gate-2 item). On the
    ///   ~33%-populated real tracks from the spike, dropping smooth_predictions
    ///   means more nil lags at feature extraction time → real bounces may be
    ///   silently suppressed. Consequence documented; not hidden.
    ///
    /// - Returns: Set of ORIGINAL-video frame indices where bounce probability > 0.45,
    ///   after consecutive-bounce collapse.
    /// - Throws: Any `MLModel` prediction error.
    public func detectBounces(
        ballPoints: [(index: Int, point: (x: Float, y: Float)?)]
    ) async throws -> Set<Int> {
        let eps: Double = 1e-15
        let threshold: Double = 0.45
        let count = ballPoints.count

        // Phase-0 postprocess operates on compacted position (not original frame
        // index): ind_bounce[i] - ind_bounce[i-1] == 1 means adjacent in the
        // guard-passing sequence. A below-threshold surviving frame between two
        // above-threshold frames DOES break the run; a nil/skipped frame does NOT
        // (it never got a compacted position). Track k for each guard-passing frame.
        struct ScoredFrame {
            let compacted: Int   // position in the guard-passing sequence
            let index: Int       // original-video frame index
            let probability: Double
        }
        var allScored: [ScoredFrame] = []
        var k = 0

        // Lags are computed positionally (faithful to pandas .shift, which is
        // positional). The returned Set<Int> uses the original-video .index.
        for n in 2..<(count - 2) {
            // All five positions must have a non-nil ball point (center + 4 lags).
            guard
                let pn   = ballPoints[n].point,
                let pn1  = ballPoints[n - 1].point,
                let pn2  = ballPoints[n - 2].point,
                let pni1 = ballPoints[n + 1].point,
                let pni2 = ballPoints[n + 2].point
            else { continue }

            // ----------------------------------------------------------------
            // 12-column feature vector (Phase-0 order: x-block then y-block)
            // Authority: bounce_detector.py → prepare_features → colnames_x + colnames_y
            //
            // x-block (abs on all families):
            //   x_diff_1, x_diff_2,
            //   x_diff_inv_1, x_diff_inv_2,
            //   x_div_1, x_div_2
            //
            // y-block (NO abs on any family):
            //   y_diff_1, y_diff_2,
            //   y_diff_inv_1, y_diff_inv_2,
            //   y_div_1, y_div_2
            // ----------------------------------------------------------------

            let xN  = Double(pn.x)
            let xL1 = Double(pn1.x);  let xL2 = Double(pn2.x)
            let xI1 = Double(pni1.x); let xI2 = Double(pni2.x)
            let yN  = Double(pn.y)
            let yL1 = Double(pn1.y);  let yL2 = Double(pn2.y)
            let yI1 = Double(pni1.y); let yI2 = Double(pni2.y)

            // x-block
            let xDiff1    = abs(xL1 - xN)
            let xDiff2    = abs(xL2 - xN)
            let xDiffInv1 = abs(xI1 - xN)
            let xDiffInv2 = abs(xI2 - xN)
            let xDiv1     = abs(xDiff1 / (xDiffInv1 + eps))
            let xDiv2     = abs(xDiff2 / (xDiffInv2 + eps))

            // y-block (no abs)
            let yDiff1    = yL1 - yN
            let yDiff2    = yL2 - yN
            let yDiffInv1 = yI1 - yN
            let yDiffInv2 = yI2 - yN
            let yDiv1     = yDiff1 / (yDiffInv1 + eps)
            let yDiv2     = yDiff2 / (yDiffInv2 + eps)

            let featureValues: [Double] = [
                xDiff1, xDiff2,
                xDiffInv1, xDiffInv2,
                xDiv1, xDiv2,
                yDiff1, yDiff2,
                yDiffInv1, yDiffInv2,
                yDiv1, yDiv2
            ]

            // Build the 12-wide MLMultiArray for this candidate frame.
            let array = try MLMultiArray(shape: [12], dataType: .double)
            for (col, value) in featureValues.enumerated() {
                array[col] = NSNumber(value: value)
            }

            // ponytail: Input feature name assumed "input" (typical for CatBoost
            // CoreML export). If convert_models.py prints a different name, update
            // this key. MLDictionaryFeatureProvider will surface a mismatch at
            // runtime with a clear error message.
            let inputFeatures = try MLDictionaryFeatureProvider(
                dictionary: ["input": MLFeatureValue(multiArray: array)]
            )
            let prediction = try await model.prediction(from: inputFeatures)

            // ponytail: Output feature name resolved dynamically from the model
            // description to avoid guessing a hardcoded string (OQ-2 ethos).
            // Confirm against convert_models.py printed spec (AC4).
            guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
                  let outputValue = prediction.featureValue(for: outputName),
                  outputValue.type == .double || outputValue.type == .int64
            else {
                k += 1
                continue
            }

            let probability: Double
            if outputValue.type == .double {
                probability = outputValue.doubleValue
            } else {
                probability = Double(outputValue.int64Value)
            }

            allScored.append(ScoredFrame(compacted: k, index: ballPoints[n].index, probability: probability))
            k += 1
        }

        // Phase-0 postprocess (bounce_detector.py:88-96): collapse runs of
        // consecutive above-threshold compacted positions to a single bounce.
        // "Consecutive" means compacted[i] - compacted[i-1] == 1 (adjacent in
        // the guard-passing sequence, regardless of original frame index gaps).
        // Within a consecutive run, keep the frame that beats its predecessor
        // (matching Phase-0's ind_bounce_filtered[-1] = ind_bounce[i] exactly —
        // not a true-maximum; a 3-run like 0.9,0.5,0.7 → keeps 0.7).
        let aboveThreshold = allScored.filter { $0.probability > threshold }
        guard !aboveThreshold.isEmpty else { return [] }

        var filtered: [ScoredFrame] = [aboveThreshold[0]]
        for i in 1..<aboveThreshold.count {
            if aboveThreshold[i].compacted - aboveThreshold[i - 1].compacted != 1 {
                // New non-consecutive bounce — start a new group.
                filtered.append(aboveThreshold[i])
            } else if aboveThreshold[i].probability > aboveThreshold[i - 1].probability {
                // Same run, current beats predecessor — replace (Phase-0 faithful).
                filtered[filtered.count - 1] = aboveThreshold[i]
            }
        }

        return Set(filtered.map { $0.index })
    }
}

// MARK: - Errors

/// Errors thrown by `BounceDetectorInference`.
public enum BounceDetectorInferenceError: LocalizedError {
    case modelNotFound

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "BounceDetector.mlmodel(c) not found in Bundle.main. " +
                   "Run cv/convert_models.py and copy the output to Resources/ML/."
        }
    }
}

#endif // !os(macOS)

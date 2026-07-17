# CV Pipeline — Setup and Model Conversion

This directory contains the Python tooling that converts Phase-0 pretrained weights into
CoreML models for on-device inference. The converted models are **not committed to git**
(both `cv/models/` and `ios/.../Resources/ML/` are gitignored). Follow the steps below
to obtain the weights, convert them, and copy the resulting CoreML packages into the iOS
app bundle.

---

## 1. Prerequisites

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r cv/requirements.txt
```

The four pins (`coremltools>=8.0`, `torch>=2.0`, `catboost>=1.2`, `numpy>=1.24`) must all
resolve. Python 3.10+ recommended; tested on 3.13.

---

## 2. Obtaining the Phase-0 weights

The two weights used by Phase 3 are:

| File | Size | Google Drive ID |
|---|---|---|
| `ball_track.pt` | ~41 MB | `1XEYZ4myUN7QT-NeBYJI0xteLsvs-ZAOl` |
| `bounce.cbm` | ~325 KB | `1Eo5HDnAQE8y_FbOftKZ8pjiojwuy2BmJ` |

Download them and place them in `cv/models/` (the directory is gitignored):

```bash
# Using gdown (pip install gdown) or any Drive download tool:
mkdir -p cv/models
gdown 1XEYZ4myUN7QT-NeBYJI0xteLsvs-ZAOl -O cv/models/ball_track.pt
gdown 1Eo5HDnAQE8y_FbOftKZ8pjiojwuy2BmJ -O cv/models/bounce.cbm
```

Drive IDs are recorded in `SPIKE_RESULT.md` (the Phase-0 results log), which is the
authoritative reference. Do not use `court.pt` or the Faster-RCNN weights; Phase 3 uses
the manual 4-corner homography from Phase 2 for court mapping and does not need court
keypoint detection.

---

## 3. Converting to CoreML

With both weights present in `cv/models/`, run:

```bash
python cv/convert_models.py
```

This script (added in Task 2):
1. Loads `ball_track.pt`, traces with a `(1, 9, 360, 640)` example input, converts via
   `coremltools.convert(...)`, and writes `cv/models/BallTracker.mlpackage`.
2. Loads `bounce.cbm` and calls `model.save_model("cv/models/BounceDetector.mlmodel",
   format="coreml")`.
3. Prints the input/output tensor specifications (name, shape, dtype) for both models to
   stdout — this output is the confirmation hook for the landscape-pixel pin and the
   CatBoost feature order (see OQ-2 below).

On success you should have:
```
cv/models/
  ball_track.pt
  bounce.cbm
  BallTracker.mlpackage/
  BounceDetector.mlmodel
```

---

## 4. Manual copy into the iOS app bundle

After conversion, copy the CoreML assets into the app target's resource folder:

```bash
RESOURCES=ios/TennisShotTracker/TennisShotTracker/Resources/ML
mkdir -p "$RESOURCES"
cp -R cv/models/BallTracker.mlpackage "$RESOURCES/"
cp    cv/models/BounceDetector.mlmodel "$RESOURCES/"
```

Both paths are gitignored. They must be present when running `xcodebuild build` (AC25).
The Xcode project references `Resources/ML/` as a resource folder (wired in Task 11).

---

## 5. 12-column CatBoost bounce feature order  *(OQ-2 RESOLVED — Task 9)*

**Authority:** `TennisProject/bounce_detector.py → BounceDetector.prepare_features`
(lines 39–48), recovered byte-for-byte. NOT guessed.

The `BounceDetectorInference` Swift class builds a 12-column `MLMultiArray` per
scoreable frame and feeds it to `BounceDetector.mlmodel`. The column order is:

```
Column index | Feature name    | Formula
-------------|-----------------|--------------------------------------------------
 0           | x_diff_1        | abs(x[n-1] - x[n])           ← abs
 1           | x_diff_2        | abs(x[n-2] - x[n])           ← abs
 2           | x_diff_inv_1    | abs(x[n+1] - x[n])           ← abs
 3           | x_diff_inv_2    | abs(x[n+2] - x[n])           ← abs
 4           | x_div_1         | abs(x_diff_1 / (x_diff_inv_1 + eps))   ← abs, eps=1e-15
 5           | x_div_2         | abs(x_diff_2 / (x_diff_inv_2 + eps))   ← abs, eps=1e-15
 6           | y_diff_1        | (y[n-1] - y[n])              ← NO abs
 7           | y_diff_2        | (y[n-2] - y[n])              ← NO abs
 8           | y_diff_inv_1    | (y[n+1] - y[n])              ← NO abs
 9           | y_diff_inv_2    | (y[n+2] - y[n])              ← NO abs
10           | y_div_1         | y_diff_1 / (y_diff_inv_1 + eps)        ← NO abs, eps=1e-15
11           | y_div_2         | y_diff_2 / (y_diff_inv_2 + eps)        ← NO abs, eps=1e-15
```

**Key asymmetry (load-bearing):** `abs` is applied to all three x-families but
**not** to any y-family. Swapping this silently produces garbage while all
shape-tests pass. The asymmetry exactly matches lines 27–32 of `bounce_detector.py`.

**Lag notation:** for array position `n`, lag_i = value at position `n-i`
(past frame), lag_inv_i = value at position `n+i` (future frame).

**Scoreable frame rule:** a frame at position `n` is only scored if ALL of
positions n-2, n-1, n, n+1, n+2 have a **non-nil** ball point. Frames near
the array ends (n < 2 or n ≥ count-2) and frames with any nil lag are skipped.

**Threshold:** bounce if predicted probability `> 0.45` (strict greater-than,
matching `np.where(preds > self.threshold)` in `bounce_detector.py`).

**Intentionally NOT ported (OQ-6=no-dedup locked):**
- `smooth_predictions` — cubic-spline gap extrapolation
- `postprocess` — consecutive-bounce deduplication filter

**Confirmation hook:** after running `python cv/convert_models.py`, the printed
`BounceDetector` input spec should show 12 columns. Verify that the feature names
match the table above (AC4). This is the final OQ-2 validation step.

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

## 12-column CatBoost bounce feature order

**Placeholder — to be filled in Task 9 (OQ-2).**

The `BounceDetectorInference` Swift class (Task 9) builds a 12-column `MLMultiArray`
per candidate frame and runs it through `BounceDetector.mlmodel`. The column order must
match the order in which features were supplied to the CatBoost model during Phase-0
training, recovered **byte-for-byte from the Phase-0 training/inference code** (the
`bounce.cbm`-producing script in `yastrebksv/TennisProject`). It must NOT be guessed.

The confirmation hook is `convert_models.py`'s printed input spec (AC4): after running
`python cv/convert_models.py`, verify that the printed `BounceDetector` input shows 12
columns and confirm the feature names match the recovered order. Document the final order
here in Task 9 before wiring `BounceDetectorInference`.

If the Phase-0 training code is unavailable, surface it as a Gate-2 blocker — do not
proceed with a guessed order (OQ-2 RISK, plan §0 / §9).

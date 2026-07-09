# Phase 0 — Results Log

## Runbook Step 1 — "does the integrated pipeline run on this machine?" → ✅ PASS

**Date:** 2026-07-08 · **Machine:** macOS (Apple Silicon), Python 3.13, CPU/MPS.

**Repo:** [yastrebksv/TennisProject](https://github.com/yastrebksv/TennisProject)
(TrackNet ball + court-keypoint net + CatBoost bounce + Faster-RCNN person).

**What ran:** full `main.py` end-to-end on a 1280×720 / 220-frame smoke clip
(upscaled from the repo's `hard.gif` demo — execution check only, not accuracy).
Ran with **no errors**; produced `out.avi` (1280×720, 220 frames).

**Per-stage completeness check** (`spike/check_ball_bounce.py`) — does each stage emit
real output on this clip?

| Stage | Result on smoke clip |
|---|---|
| Court keypoints / homography | ✅ confirmed — keypoints + outline drawn (see extracted frame) |
| Player detection | ✅ confirmed — bounding box drawn |
| Ball tracking (TrackNet) | ✅ **72 / 220** frames have a real ball point |
| **Bounce detection (CatBoost)** | ❌ **0 bounces** on this clip |

**The bounce stage — the whole point of the spike — produced nothing here.** Most
likely cause: the ball track is only ~33% populated (fragmented trajectory from a
low-quality upscaled GIF), and the bounce model needs a fairly continuous trajectory
to detect the velocity-reversal. This is **not** evidence the detector is broken — it
is evidence we **cannot confirm bounce detection on degraded footage**, and that
bounce detection (the make-or-break stage) remains **fully open** until tested on
decent footage. Do not read Step 1 as "the pipeline detects bounces."

**Pretrained weights downloaded (Google Drive):**
- ball_track.pt (41M) — TrackNet — `1XEYZ4myUN7QT-NeBYJI0xteLsvs-ZAOl`
- court.pt (40M) — TennisCourtDetector — `1f-Co64ehgq4uddcQm1aFBDtbnyZhQvgG`
- bounce.cbm (325K) — CatBoost bounce — `1Eo5HDnAQE8y_FbOftKZ8pjiojwuy2BmJ`
- fasterrcnn (160M) — auto-downloaded by torchvision for person detection.

**Env note:** repo pins are ancient (torch 1.5, numpy 1.19) and do NOT install on
Python 3.13. Installed **relaxed modern** versions instead: torch 2.13, numpy 2.x,
opencv 5.0, catboost, scenedetect — code runs fine after two small compat shims.

**Compat shims applied (spike-only, marked `ponytail:`):**
1. `utils.py` — `scenedetect` `VideoManager` → modern `open_video` API.
2. `homography.py` — `np.Inf` → `np.inf` (removed in NumPy 2.0).

**Cost/perf:** ball detection ≈ 3 it/s on CPU (~70s / 220 frames). Fine for offline
post-recording processing; on-device speed is a **separate later gate**, not Phase 0.

### What Step 1 does and does NOT prove
- ✅ The integrated pipeline installs and executes on this hardware; court/homography,
  player detection, and **ball tracking** all emit real output.
- ⚠️ **Bounce detection is unconfirmed** — 0 bounces on the degraded smoke clip. The
  spike's central question is therefore still open; it needs decent footage.
- ❌ It does **NOT** prove the pass/fail gate (≥80% correct-zone bounce localization).
  That is untested — it requires labeled footage, per `SPIKE.md`.

> **First thing to check in Step 2:** on the very first real clip, confirm bounce
> count > 0 *before* investing in labeling. If good footage still yields ~0 bounces,
> the bounce model needs work (retrain/replace) — surface that early.

---

## Runbook Step 2 — public footage + labeled eval → ⏳ NOT STARTED (needs footage)
## Runbook Step 3 — phone footage @ real court → ⏳ NOT STARTED (**this is the real Phase-1 gate**)

**Blocked on you:** one public clip and one fixed-position phone clip (all 4 court
corners in frame), plus 30–50 hand-labeled bounces (`frame_idx, true_zone`) per clip.
See `SPIKE.md` → "Ground-truth labeling" and the gate.

## Reproduce Step 1
```
spike/.venv/bin/python spike/TennisProject/main.py \
  --path_ball_track_model spike/models/ball_track.pt \
  --path_court_model      spike/models/court.pt \
  --path_bounce_model     spike/models/bounce.cbm \
  --path_input_video      <1280x720 clip> \
  --path_output_video     spike/out.avi
```
(`spike/` contents are git-ignored — throwaway.)

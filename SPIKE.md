# Phase 0 — CV Feasibility Spike

> **Throwaway experiment.** The deliverable is a **yes/no answer**, not reusable code.
> Pretrained models, hardcoded court corners for one clip, hand-labeled eval set.
> Do not build the app around this until the gate below passes on **phone footage**.

## The single question

> Can the pipeline localize a ball **bounce** to the correct court zone, from a
> single fixed camera, accurately and consistently?

Everything in `DESIGN.md` (auto-CV premise) rides on this. If it fails, the fallback
is **manual tap-to-tag** and auto-CV moves to v2.

## Why single-camera is even viable (where the risk is NOT)

At the **instant of the bounce**, the ball is on the court plane (z=0). A homography
(built from 4 known court points) maps that pixel directly to a real court coordinate —
**no 3D reconstruction needed**. So localization-given-the-right-frame is basically
solved geometry.

**The risk is almost entirely in step 3: detecting *which frame* is the bounce.** A
bounce is a velocity-reversal "kink" in the trajectory and is easily confused with the
arc's apex. → Use an **existing trained bounce detector**, never a hand-rolled
y-extremum heuristic.

## Pipeline (evaluate each stage separately)

1. **Court calibration → homography.** Spike: hardcode the 4 corner pixels for one
   clip (in the app this becomes the 4-corner tap). image→court mapping.
2. **Ball detection + tracking** — TrackNet-family, pretrained.
3. **Bounce-frame detection** — trained bounce model (THE make-or-break stage).
4. **Zone classification** — bounce pixel → homography → court coords → zone.

## Candidate repos (use these, don't assemble from scratch)

- **Primary:** [yastrebksv/TennisProject](https://github.com/yastrebksv/TennisProject)
  — TrackNet + court keypoints + bounce detection, integrated, pretrained weights.
- **Cross-check:** [ArtLabss/tennis-tracking](https://github.com/ArtLabss/tennis-tracking)
  — monocular HawkEye; reported bounce detection 83% TP / 98% TN.

Verify pretrained weights download and run on the laptop **before** writing any glue.

---

## ✅ PASS/FAIL GATE — locked now, before any results

**Primary metric — zone accuracy given a correct bounce frame (stage 4):**
- **≥ 80%** of correctly-detected bounces assigned to the **correct zone**.
- Equivalently: **median court-coordinate error < half a zone width.**

**Supporting metrics — reported, not gated (they tell us *which* stage failed):**
- Ball-detection recall (stage 2).
- Bounce-frame precision & recall (stage 3) — the expected weak link.

**Reading the result:**
- Stage 4 ≥ 80% but stage 3 recall low → geometry works, bounce detector is weak →
  *actionable* (swap/tune detector), premise still alive.
- Stage 4 < 80% even on correct frames → **premise dead** → fall back to manual tap.

Writing the 80% down **now** is the point — no moving the goalpost after seeing numbers.

---

## Ground-truth labeling — THIS is the actual work

A metric needs labels. Everything else is just downloading a model.

- Pick **one clip**. Hand-label **30–50 bounces**: for each, the frame index and the
  **true zone** (what a human sees). Store as CSV: `frame_idx, true_zone`.
- This labeled set is the eval oracle. Without it the spike is a demo, not a decision.

---

## Two separate verdicts — do not conflate

| Footage | What a pass means |
|---|---|
| **Public/broadcast** (step A) | Plausibility only: "the stages *can* work" on clean, high, single-angle video. **NOT** a project green-light. |
| **Phone @ your court** (step B) | **The real gate.** Low angle, clutter, variable light — the actual deployment condition. This is what decides Phase 1. |

A public-footage pass must not be over-read as "auto-CV is proven."

---

## Runbook

1. Clone primary repo; download pretrained weights; run its demo on a sample clip
   (confirm it executes end-to-end on the laptop).
2. **Step A — public footage:** grab one broadcast/public tennis clip. Hardcode the 4
   court corners. Hand-label 30–50 bounces (frame + zone). Run pipeline; compute the
   gate + supporting metrics. Record verdict.
3. **Step B — phone footage:** film one clip from a fixed phone position at a real
   court with all 4 corners in frame. Repeat labeling + metrics. **This verdict gates
   Phase 1.**
4. Write the numbers and the go/no-go into `SPIKE_RESULT.md`.

## Scope guards (things the spike must NOT drift into)

- ❌ **No CoreML / on-device work.** Run in Python on the laptop. On-device perf is a
  *separate later gate*, not a Phase-0 question.
- ❌ **No training.** Pretrained weights only. Training in a spike defeats its purpose.
- ❌ **No auto court-line detection.** Hardcode corners; the app will use the 4-tap.
- ❌ **No app/DB/API code.** Phase 1 starts only after step B passes.

## Environment (verified available)

Python 3.13, pip, ffmpeg present on this machine. Spike deps (torch/opencv/etc.) come
from the chosen repo's `requirements.txt` — install in a throwaway venv under `spike/`.

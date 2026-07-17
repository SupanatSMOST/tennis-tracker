# Code Review: CV Integration — On-Device CoreML Post-Processing (Phase 3)

**Date:** 2026-07-17
**Reviewer:** reviewer (AI)
**Branch:** `feat/phase3-cv` (17 commits ahead of `origin/main`)
**Verdict:** CHANGES-REQUIRED (cycle 1) → **PASS-WITH-NITS** (cycle 2, after fix commit `cfc5576` — see final section)

Real test gate re-run: `cd ios/TennisCore && swift test` → **144 tests, 0 failures**
(119 Phase-1/2 baseline + 25 new Phase-3). Meets the spec §10 / AC24 hermetic
target exactly. Confirmed no CoreML model file present and the four `#if !os(macOS)`
inference/extractor files are excluded from the macOS test build.

The testable layer (value types, protocols, mocks, `CVPipeline` coordinate chain,
`PostProcessingViewModel`) is excellent — the crown-jewel coordinate chain is
implemented verbatim row-major, the transpose guard is real and load-bearing, the
`source:"cv"` path is correct, and the zone enum is byte-for-byte the six values.

The **CHANGES-REQUIRED** verdict is driven entirely by the two `#if`-guarded,
zero-test-coverage inference files (`BallTrackerInference`, `BounceDetectorInference`),
where a provably-inverted threshold (BLOCKER) and two dropped Phase-0 functions
justified by a factually-wrong OQ citation (SHOULD-FIX) would silently produce wrong
output on-device. These are exactly the files that no CI gate can catch (Flag 3), so
they must be corrected in source before the on-device validation gate rather than
discovered there.

---

## Spec Compliance (per AC)

### Python / model conversion (manual — not in `pytest`)
- [~] AC1: `cv/requirements.txt` pins `coremltools>=8.0`, `torch>=2.0`, `catboost>=1.2`,
  `numpy>=1.24` — present and correct (`cv/requirements.txt`). Clean-venv `pip install`
  **not empirically run in this env** — annotate as implemented, manual-run pending.
- [~] AC2: `convert_models.py:198-225` traces TrackNet with `torch.zeros(1,9,360,640)`,
  `ct.convert(convert_to="mlprogram")`, saves `BallTracker.mlpackage`. Structurally
  correct; **not run** (no weights in env). Implemented, manual-run pending.
- [~] AC3: `convert_models.py:228-243` loads CatBoost, `save_model(..., format="coreml")`
  → `BounceDetector.mlmodel`. Implemented, manual-run pending.
- [~] AC4: `_print_model_specs` (`convert_models.py:179-195`) prints name/shape/dtype for
  both models' inputs+outputs. Implemented, manual-run pending.
- [x] AC5: `cv/README.md` covers weight fetch (Drive IDs), conversion, manual copy into
  `Resources/ML/`, **and** the recovered 12-column feature order (§5). Verified.

### TennisCore — `MockCVPipeline` / `CVProcessing` contract (`swift test`)
- [x] AC6: 0 stubbed → `[]`, no throw. Tested (`MockCVPipelineTests`).
- [x] AC7: N stubbed → N in order. Tested.
- [x] AC8: stubbed error → throws. Tested.

### TennisCore — `CVPipeline` coordinate chain (`swift test`)
- [x] AC9: Six zones, asymmetric calibration, one pixel each. `CVPipelineTests:136-260`.
- [x] AC10: `ballPixelX/Y == input`, `normalizedCourtX/Y == row-major chain`, recomputed
  independently in-test (not tautological). `CVPipelineTests:267-327`.
- [x] AC11: nil-ball bounce skipped, `{a(nil),b}`→count 1. Tested.
- [x] AC12: empty bounce set → `[]` regardless of tracked balls. Tested.
- [x] AC13: monotonic progress in [0,1], ≥1 call, final 1.0. `CVPipeline.process`
  emits 0.0/0.33/0.66/0.90/1.0. Tested.
- [x] AC14: one result per (bounce frame, non-nil ball), bounce-frame order. Tested.
  `CVPipeline` correctly iterates `frames.indices`, guards on `bounceSet.contains(frameIndex)`
  and `balls[i] != nil`, and never mis-indexes `balls` by `frame.index` (A-6 correct
  under stride > 1).
- [x] AC15: **Transpose guard — load-bearing, genuinely divergent.** `CVPipelineTests:494`
  searches for a pixel where row-major and column-major chains classify differently,
  self-verifies via `XCTAssertNotEqual(rowMajorZone, transposedZone)`, then asserts the
  row-major zone. `CVPipeline.swift:133-135` applies `m[3r+c]` verbatim — no `simd_float3x3`
  reconstruction, no `HomographyService` reuse. Correct.

### TennisCore — `PostProcessingViewModel` (`swift test`)
- [x] AC16: initial `.idle`. `PostProcessingViewModel:38`.
- [x] AC17: `.idle→.processing→.done(N)`. Tested.
- [x] AC18: pipeline throws → `.failed`, never `.done`/crash. Tested.
- [x] AC19: submit calls `addShots` with N shots, **every `source:"cv"`**
  (`PostProcessingViewModel:153`), each zone from the result. Tested against StubTransport body.
- [x] AC20: every submitted zone is one of the six (produced by `ZoneClassifier`, never a
  literal). Tested.
- [x] AC21: submit transport failure → `.failed`, `detectedShots` retained; `submit` can
  re-enter `.done` and retry (`PostProcessingViewModel:140-161`). Tested.
- [x] AC22: `dismiss()` → `.idle`, clears retained shots. Tested.
- [x] AC23: missing video OR missing calibration → `.failed`, pipeline not run
  (`PostProcessingViewModel:89-100`). Two temp-dir guard cases tested.

### TennisCore — hermetic / no-CoreML gate
- [x] AC24: 144 tests, 0 failures, no model file, `#if !os(macOS)` inference files
  excluded. Re-run confirmed. (Protocol files' `#if !os(macOS)` appear only in doc
  comments, not real guards — protocols correctly compile on macOS.)

### App target — build only (inspection; orchestrator ran the typecheck compensator)
- [~] AC25: `xcodebuild build` not runnable (no simulator runtime — env-blocked, deferred
  Gate-2 item per Phase 1/2 precedent). Orchestrator ran the `swiftc -typecheck`
  compensator = 0 errors; not independently re-run here.
- [x] AC26: `MatchSummaryView:164-167` gates "Analyse Video" on
  `videoStore.exists(for:) && calibrationStore.exists(for:)`. Verified by inspection.
- [x] AC27: `PostProcessingView` renders `ProgressView(value:progress).linear` bound to
  `.processing(progress)` + a Cancel button → `vm.dismiss()`; `CVShotReviewView` lists
  results with per-row zone badges, `Submit N` → `vm.submit`, `Discard` → `vm.dismiss()`.
  Verified.
- [x] AC28: No CV/zone/coordinate/networking logic in the app target — the composition
  root (`MatchSummaryView.startAnalysis`) only constructs `CVPipeline` + VM; views are
  thin readers. Verified. (Composition root correctly wrapped in `#if !os(macOS)`,
  `try` not `try!` so a missing model surfaces an alert rather than crashing.)
- [x] AC29: `Package.swift` deps `[]` / `["TennisCore"]`; CoreML/AVFoundation are system
  frameworks. No new dependency. Verified.

`source:"cv"` end-to-end: **CORRECT.** `PostProcessingViewModel:153` builds
`ShotInput(zone:$0.zone, source:"cv")` → existing `MatchClient.addShots` → existing
`POST /matches/{id}/shots`. No new DTO/route/backend/migration. Zone strings are the six
`ZoneClassifier` values byte-for-byte; no `out_behind`, no casing drift (`ZoneClassifier.swift:26-32`).

---

## Ruling on the three flags

### Flag 1 — dropped Phase-0 bounce functions → SHOULD-FIX (two distinct issues)

The orchestrator's framing ("OQ-6 covers only `postprocess` dedup") is **partly wrong**,
and the coder's in-code justification is **factually false for both dropped functions**.
Re-reading OQ-6 (spec §11): OQ-6 is about **re-analysis** — tapping "Analyse Video" twice
appends duplicate rows *across separate runs*. It covers **neither**:

1. **`smooth_predictions` dropped** (`BounceDetectorInference.swift:72` cites "OQ-6=no-dedup
   locked" — false). Authority: `bounce_detector.py:50-52,61-78` — `predict(smooth=True)`
   runs it **by default** BEFORE `prepare_features`, cubic-spline-interpolating ≤5-frame
   gaps in the ball track. Consequence of dropping it: on the fragmented real tracks the
   spike already observed (`SPIKE_RESULT.md`: only 72/220 frames have a ball, "~33%
   populated"), the Swift port's requirement that all five positions n-2…n+2 be non-nil
   (`BounceDetectorInference.swift:87-95`) will skip far more candidate frames than Phase-0
   did after smoothing → **real bounces silently suppressed.** This directly contradicts
   spec §1 "reuse the **proven** Phase-0 pipeline."

2. **`postprocess` (consecutive-bounce collapse) dropped** (`BounceDetectorInference.swift:73`
   also cites "OQ-6" — false; this is *within-run* dedup, unrelated to OQ-6's *cross-run*
   re-analysis). Authority: `bounce_detector.py:57,88-96` — `predict` collapses a run of
   consecutive `preds>0.45` frames to a single bounce (keeps the max-prob frame).
   Consequence of dropping it: one physical bounce firing on N consecutive frames →
   **N `CVShotResult`s → N duplicate `cv` shots submitted** for a single bounce.

**Ruling: SHOULD-FIX for both.** Severity below BLOCKER only because (a) the layer is
build-only / on-device-validated by design (§9), and (b) A-10 de-scopes *model efficacy*.
But the review must not let the OQ-6 rationalization stand. Required of the coder:
(i) correct the false "OQ-6=no-dedup locked" comments; (ii) port `postprocess`
(within-run consecutive-bounce collapse) — it is cheap, has a concrete user-facing
duplicate-shot consequence, and is not de-scoped by any OQ; (iii) either port
`smooth_predictions` or record it explicitly as a known Phase-0-fidelity gap to be closed
at the on-device numerical-parity gate (not hidden behind a wrong OQ citation).

### Flag 2 — BallTracker seven deviations → one BLOCKER, rest NIT

Worked the arithmetic the header (`BallTrackerInference.swift:23-28`) dismisses as
"chaotic wrapping":

- TrackNet emits `(1,256,H,W)`; `out.argmax(dim=1)` gives a per-pixel channel index
  `f ∈ {0..255}` — the quantized intensity (ball → high-value channel).
- Phase-0 `ball_detector.py:54` does `feature_map *= 255`. Since `255 ≡ −1 (mod 256)`,
  `f*255 mod 256 = (256−f)` for f≥1 — a **clean inversion**, not chaos (f=255→1, f=128→128,
  f=1→255).
- Phase-0 `ball_detector.py:57` `cv2.threshold(...,127,THRESH_BINARY)` keeps value>127 →
  `256−f>127` → **f ∈ {1..128}** is selected as ball.
- Swift `BallTrackerInference.swift:294` keeps `maxIdx >= 128` → **f ∈ {128..255}**.

These bands are near-disjoint (overlap only at 128). The spike proves Phase-0 produced
real ball tracks (72/220 frames) **with the wrap in place**, so the ball genuinely lives in
Phase-0's selected band. The Swift port selects the **opposite band** → it will pick
background pixels and drop the real ball, feeding silent-garbage coordinates into the
(otherwise correct) coordinate chain and zone classifier.

**Ruling: BLOCKER.** FR-C5 explicitly requires "applies the **Phase-0 post-processing** in
Swift — `argmax → threshold → centroid → ×2`". This is a spec-named reproduction step, not
model-accuracy tuning — so A-10 does **not** cover it. The threshold direction is provably
inverted relative to the proven Phase-0 pipeline; the coder's "sane simplification"
rationale (header (c)) rests on a mischaracterization of the transform as unpredictable.
Fix: reproduce Phase-0's effective selection (apply the `f→256−f` wrap then threshold >127,
i.e. keep low argmax indices), OR confirm empirically against the converted model + a
Phase-0 clip which band actually holds the ball and align the threshold to it. Document
the confirmed direction.

The other six deviations:
- **BGRA input precondition → NIT (documented, matching).** Verified `FrameExtractor.swift:49-54`
  sets `kCVPixelFormatType_32BGRA`, exactly matching `BallTrackerInference.writeFrame`'s
  BGRA assumption. Correct coupling, well-documented; no bug.
- **Centroid vs HoughCircles → NIT.** Graceful degradation for a compact blob; acceptable v1.
- **No prev_pred/max_dist=80 temporal outlier filter → NIT.** Loses outlier rejection;
  acceptable v1, deferred refinement. (Note: pairs with the dropped `smooth_predictions`
  in reducing track quality — worth a combined note at the on-device gate.)
- **Nearest-neighbour vs bilinear resize → NIT.** Minor fidelity; acceptable v1.
- **float32 output requirement → NIT (good).** Runtime guard throwing on float16 is a
  correct fail-loud choice.
- **argmax-index-as-intensity → subsumed by the BLOCKER above** (the intensity semantics
  are exactly what the threshold-direction fix must reconcile).

### Flag 3 — no iOS compile gate until Task 11 → NIT (process) + required on-device parity check

Confirmed the process gap: macOS `swift test` structurally cannot compile the four
`#if !os(macOS)` files, so Tasks 7–9 were unverified until the Task-11 typecheck surfaced
the await bug. These files also have **zero automated test coverage by design**. That
combination is precisely why the Flag-2 inversion and the Flag-1 fidelity gaps could ship
undetected — no gate in this phase's CI touches them numerically.

**Recommendation (NIT / process, does not block merge on its own):**
1. Add a lightweight iOS `swiftc -typecheck` (or `xcodebuild build`) CI step over the
   `#if !os(macOS)` sources so these files are at least compile-verified on every change,
   not once at the end of the pipeline.
2. More importantly, the on-device validation gate MUST include a **numerical-parity check
   vs Phase-0 on the same clip** (ball points and bounce frames). Compile-checking cannot
   catch a threshold inversion or a dropped smoothing pass — only running the converted
   models against a known clip and comparing to Phase-0 output can. Make this an explicit
   Gate-2 / Phase-0-efficacy checklist item.

---

## BLOCKER / SHOULD-FIX / NIT summary

**BLOCKER (route to coder):**
- `BallTrackerInference.swift:294` — ball-detection threshold direction is provably inverted
  relative to Phase-0. Phase-0 selects argmax band `f∈{1..128}` (after the `f→256−f` wrap);
  Swift selects `f∈{128..255}` (opposite). Produces silent wrong ball coords. FR-C5 pins
  this as a Phase-0 reproduction (not A-10 model-accuracy). Fix + document the confirmed band.

**SHOULD-FIX (route to coder):**
- `BounceDetectorInference.swift:72-73` — false "OQ-6=no-dedup locked" justification for
  dropping two distinct Phase-0 functions. (a) Correct the comments. (b) Port `postprocess`
  (within-run consecutive-bounce collapse — not covered by any OQ; dropping it submits
  N duplicate shots per physical bounce). (c) Port `smooth_predictions` OR record it as an
  explicit known fidelity gap for the on-device parity gate.

**NIT (coder discretion / Gate-2 notes):**
- Flag-2 residual deviations (centroid, no temporal filter, NN resize) — acceptable v1;
  the "no temporal filter" + dropped smoothing together degrade track quality, note at gate.
- Flag-3 — add an iOS-compile CI step for the `#if` files; add an on-device Phase-0
  numerical-parity check to the validation gate (the only thing that catches the BLOCKER
  class of defect).
- AC1–AC4 — implemented but empirically unverified in this env (no model weights / clean
  venv run). Annotate as manual-run-pending, not proven (mirrors the Phase-2 build-only ACs).
- `BallTrackerInference` / `BounceDetectorInference` model input/output feature-name keys
  (`"input"`, dynamic output-name lookup) carry `ponytail:` comments to confirm against
  `convert_models.py`'s printed spec (AC4) once the manual run happens — correct posture.

## Auto-fixes Applied
None. Every finding is either a logic/fidelity issue routed to the coder (per instructions,
not auto-fixed) or a NIT. No typos or trivial cleanups warranting a separate commit were
found in the reviewed diff.

## Summary
The testable core of Phase 3 is high quality: the row-major coordinate chain is verbatim
and guarded by a genuinely-divergent transpose test, `source:"cv"` is wired correctly with
no schema/route change, the six-value zone enum is preserved byte-for-byte, and 144 tests
pass hermetically with no model file. The defects are confined to the two zero-test-coverage
`#if`-guarded inference files: a provably-inverted ball-detection threshold (BLOCKER) and
two dropped Phase-0 bounce functions defended by a factually-incorrect OQ-6 citation
(SHOULD-FIX). Because no CI gate in this phase exercises those files numerically (Flag 3),
they must be fixed in source now rather than surfaced at the on-device gate. Verdict:
**CHANGES-REQUIRED** — route the BLOCKER + SHOULD-FIX list to the coder (cycle 1 of max 2).

---

## Review cycle 2 — fix verification

**Date:** 2026-07-17
**Scope:** Bounded confirmation pass over fix commit `cfc5576` (3 files:
`BallTrackerInference.swift`, `BounceDetectorInference.swift`, `cv/README.md`).
NOT a full re-review. iOS compile (0 errors, both `#if` files) and macOS
`swift test` (144 green) independently confirmed by orchestrator — not re-run here.

### Item 1 — BLOCKER: ball-detection threshold direction → **PASS**
`BallTrackerInference.swift` now (line ~299) computes
`let wrappedValue = (maxIdx * 255) % 256; if wrappedValue > 127`, with `maxIdx`
changed from `Float` to `Int` and the `detectionThreshold` constant removed. This
is byte-equivalent to Phase-0 `ball_detector.py:54,57` (`feature_map *= 255` →
`astype(uint8)` → `cv2.threshold(...,127,THRESH_BINARY)`): numpy `astype(uint8)`
on non-negative int is `mod 256`, exactly `% 256`; `maxIdx ∈ {0..255}` is always
non-negative (no sign issue). Verified band selection:
f=0→0 (excluded, background ✓), f=1→255 (>127 ✓), f=128→128 (>127 ✓),
f=129→127 (excluded ✓), f=255→1 (excluded ✓) → selects exactly **f ∈ {1..128}**,
reproducing Phase-0's `256−f > 127`. It is **NOT** a naive `<= 128` flip (that
would wrongly include f=0 background). An in-code comment explicitly warns against
the `<= 128` simplification. Inversion corrected.

### Item 2 — SHOULD-FIX (a): false OQ-6 comments → **PASS**
The "OQ-6=no-dedup locked" justifications are gone from both files.
`BounceDetectorInference.swift` now states `postprocess` "is a within-run operation…
distinct from OQ-6 (which covers cross-run re-analysis)"; `cv/README.md` §5 mirrors
this. Truthful and consistent with the spec §11 OQ-6 definition.

### Item 3 — SHOULD-FIX (b): postprocess consecutive-bounce collapse → **PASS**
Ported faithfully in `detectBounces` (lines ~203-224) against
`bounce_detector.py:88-96`. Confirmed via Phase-0 `predict()` that `preds`/`ind_bounce`
are **compacted-position** indexed (rows survive `prepare_features` NaN-drop in
compacted order; `num_frames` maps back to original index at the end). The Swift port
mirrors this exactly: `ScoredFrame.compacted == ind_bounce[i]` and
`.probability == preds[ind_bounce[i]]`, so the run-break test
(`compacted[i] − compacted[i-1] != 1`) and the predecessor-comparison replace
(`> aboveThreshold[i-1].probability`) map 1:1 to Phase-0 lines 89-95 — including the
non-max quirk (keeps the last frame that beats its predecessor, e.g. 0.9,0.5,0.7 →
0.7, not the true max). The nil-ball guard `continue` (line 117) correctly does NOT
advance `k` (those frames were NaN-dropped in Phase-0 and never got a compacted slot).
A run of N consecutive above-threshold frames now collapses to one bounce →
prevents N duplicate `cv` shots per physical bounce.

*Micro-nit (transparency, does not block):* the `k += 1` on the model-output-parse
failure `continue` (line 188) is a Swift-only path with no Phase-0 analog — CatBoost
`predict` always returns a float for every guard-passing row, so Phase-0 has no
mid-sequence compacted-position gap. Incrementing `k` there makes a failed frame break
runs on both sides; not incrementing would merge its neighbours. Both are defensible;
neither is strictly "Phase-0 faithful" since Phase-0 has no such gap. In practice a
malformed model fails for *all* frames (→ `allScored` empty → returns `[]`), so this
path has no realistic mid-sequence impact. Recorded for completeness; carry to the
on-device parity gate.

### Item 4 — SHOULD-FIX (c): smooth_predictions → **PASS** (documented gap, honest)
Not ported; documented as an **explicit Phase-0-fidelity gap** in BOTH
`BounceDetectorInference.swift` (header, lines ~74-82) and `cv/README.md` §5 ("Known
Phase-0 fidelity gap"). Both spell out the consequence (dropping cubic-spline gap
extrapolation → more nil lags at feature-extraction time → real bounces may be silently
suppressed on the ~33%-populated real tracks), the reason (scipy `CubicSpline` has no
clean Swift equivalent; porting risks silent numerical divergence), and the closure
mechanism (on-device Phase-0 numerical-parity gate, Gate-2 item). No longer hidden
behind a wrong OQ-6 citation. Honest and traceable.

### Cycle-2 outcome
All four fix items (1 BLOCKER, 3 SHOULD-FIX) correctly addressed. The BLOCKER
threshold inversion is provably corrected to Phase-0's exact band; the false OQ-6
citations are corrected; `postprocess` is ported byte-faithfully; `smooth_predictions`
is honestly documented as a gap for the parity gate.

**Cycle-1 NITs carried forward as documented Gate-2 notes (do NOT block):**
- Centroid vs HoughCircles (acceptable v1 for a compact blob).
- No temporal prev-frame outlier filter (acceptable v1; pairs with the dropped
  `smooth_predictions` in reducing track quality — note the combined effect at the gate).
- Nearest-neighbour vs bilinear resize (minor fidelity, acceptable v1).
- Add a lightweight iOS `swiftc -typecheck` / `xcodebuild build` CI step over the
  `#if !os(macOS)` sources (process gap — these files have no automated numerical coverage).
- On-device Phase-0 **numerical-parity check** vs Phase-0 on the same clip (ball points +
  bounce frames) — the only gate that catches the threshold-inversion / dropped-smoothing
  class of defect. Must be an explicit Gate-2 checklist item.
- AC1–AC4 — implemented but empirically unverified in this env (no model weights / clean
  venv run); annotate manual-run-pending, not proven.

### Updated overall verdict: **PASS-WITH-NITS**
All BLOCKER + SHOULD-FIX items from cycle 1 are correctly resolved in commit `cfc5576`.
The remaining items are the carried-forward cycle-1 NITs (Gate-2 notes), none of which
block merge. Cleared for Gate-2 human PR review, with the on-device numerical-parity
check as the required efficacy gate.

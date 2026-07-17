# Spec: CV Integration — On-Device CoreML Post-Processing (Phase 3)

**Date:** 2026-07-17
**Phase:** Phase 3 (CV integration — wire the proven Phase-0 pipeline into the record flow)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Wire the proven Phase-0 CV pipeline into the iOS app as **on-device CoreML
post-processing**, triggered by the user after a match is recorded. On the match
detail screen the user taps **"Analyse Video"**; the pipeline (1) extracts frames
from the locally-stored `.mov`, (2) runs the TrackNet ball tracker to get a
per-frame ball point, (3) runs the CatBoost bounce detector to get the set of
bounce frames, (4) for each bounce with a valid ball point maps the ball pixel →
court-normalized coordinate via the **Phase-2 homography**, (5) classifies that
court point into one of the six backend zones via the existing `ZoneClassifier`,
and (6) submits the results as `source: "cv"` shots through the existing
`MatchClient.addShots` route. Everything runs **on-device, post-recording,
user-triggered** — no server-side CV, no real-time processing, no cloud. This is
Phase 3 of the roadmap: it reuses the Phase-0-validated models (converted to
CoreML) and the Phase-2 calibration/video seams, and it produces `record` rows
that are indistinguishable to the backend from manual shots except for
`source = 'cv'`.

## 2. Critical Architectural Constraint (non-negotiable)

**CoreML lives entirely outside the testable layer.** Every model-backed type
(`BallTrackerInference`, `BounceDetectorInference`) sits behind a Swift protocol
(`BallTracking`, `BounceDetecting`) and is guarded by `#if` so it does not compile
into the macOS `swift test` build and does not require a model file to exist. The
orchestrating pipeline (`CVPipeline`) and the view model (`PostProcessingViewModel`)
depend only on the **protocols**, never on the concrete CoreML types, so they are
fully `swift test`-able with mocks (`MockCVPipeline`, `MockBallTracker`,
`MockBounceDetector`). Consequences enforced by this spec:

- The `swift test` suite never instantiates a real CoreML model and never reads a
  `.mlpackage`/`.mlmodel` file. The model files are gitignored (§8) and absent in
  CI; the testable layer must compile and pass with them absent (AC-hermetic).
- Zone classification remains **on-device and client-owned** (Phase-1 constraint,
  `spec-ios-gameplay-2026-07-10.md` §2): the CV pipeline maps a ball point to a
  court point and feeds it into the **existing** `ZoneClassifier` against the unit
  rect `CGRect(0,0,1,1)`. It does **not** invent a new zone taxonomy — it reuses
  the six-value backend enum byte-for-byte (§3.1).
- `source: "cv"` requires **no backend change, no client-model change**. The
  existing `ShotInput(zone:source:)` already carries a `source` field
  (default `"manual"`) and `MatchClient.addShots(matchID:shots:) -> Int` already
  posts it (both verified on `feat/phase2-camera`). The pipeline simply builds
  `ShotInput(zone: z, source: "cv")` (§3.2).

## 2b. Base branch note (RESOLVED — branch off `main`)

The task instructed "branch off `main`," and that is **correct**. Phase 2 **is
merged to `origin/main`** as PR #4 (merge commit `bdec000` "Feat/phase2 camera
(#4)"), verified via `git fetch` + `git merge-base --is-ancestor bdec000
origin/main`. Every Phase-3 dependency — `HomographyService`,
`CourtCalibration`/`CalibrationStore`, `LocalVideoStore`, `ZoneClassifier`, and the
`Camera/` and `Calibration/` directories — is present on `origin/main`.

The Phase-3 work branch `feat/phase3-cv` is therefore **based on `origin/main`**
(`bdec000`), and its PR targets `main`. No stacked-PR / retarget decision is needed.

> Correction note (for the record): an earlier draft of this section claimed
> branching off `main` was "impossible" because Phase 2 appeared unmerged. That was
> an artifact of a **stale local `main`** ref that predated PR #4; the remote
> `origin/main` already contained Phase 2. The branch was re-pointed to
> `origin/main`; the working-tree content was identical (empty diff), so there is no
> build impact. There is no base-branch deviation to defer to Gate 2.

## 3. Scope

### 3.1 Zone strings — hard requirement (exact match to backend enum)

The pipeline MUST emit exactly one of these six strings and no others, matching the
backend enum byte-for-byte (lower snake_case) — the **same set** as manual shots,
with **no `out_behind`**:

```
front_court_left
front_court_right
baseline_left
baseline_right
out_left
out_right
```

These are produced solely by reusing `ZoneClassifier.classify(point:in:)` against
`CGRect(0,0,1,1)` — the pipeline never constructs a zone string literal itself.

### 3.2 `source: "cv"` — no schema, no model, no client change

Verified on `feat/phase2-camera`:

- `ShotInput` (in `Models/MatchModels.swift`) is
  `init(zone: String, source: String = "manual")` with `source` a stored property
  that always encodes.
- `MatchClient.addShots(matchID: String, shots: [ShotInput]) async throws -> Int`
  posts `{"shots":[{"zone":"…","source":"…"},…]}` to `POST /matches/{id}/shots`.

Therefore a `cv` shot is `ShotInput(zone: z, source: "cv")` submitted through the
existing `addShots`. **No new DTO, no `MatchClient` change, no backend change, no
migration.** The backend stores whatever `source` string the client sends.

### In scope

- **Python `cv/` (new directory, this branch):**
  - `cv/requirements.txt` — `coremltools>=8.0`, `torch>=2.0`, `catboost>=1.2`,
    `numpy>=1.24`.
  - `cv/convert_models.py` — converts the two Phase-0-validated model weights to
    CoreML (§7 CV-1..CV-4). Run **manually**, not in `pytest`.
  - `cv/models/` — gitignored output directory for source weights + converted
    packages (§8).
  - `cv/README.md` — setup doc: how to obtain the Phase-0 weights, run
    `convert_models.py`, and **manually copy** the converted `.mlpackage`/`.mlmodel`
    into `ios/TennisShotTracker/TennisShotTracker/Resources/ML/`.
- **TennisCore `CV/` (new, `swift test`-able through protocols):**
  - `CVProcessing` protocol + `CVShotResult` struct.
  - `MockCVPipeline` (test double: `stubbedResults`, `stubbedError`).
  - `FrameExtracting` protocol + `FrameExtractor` (AVFoundation-backed, `#if`-guarded)
    + `MockFrameExtractor` (unguarded test double — `CVPixelBuffer` is CoreVideo and
    compiles on macOS, so the pipeline tests can feed frames without the concrete
    AVFoundation extractor).
  - `BallTracking` protocol + `BallTrackerInference` (CoreML-backed, `#if`-guarded,
    **no `swift test`s**).
  - `BounceDetecting` protocol + `BounceDetectorInference` (CoreML-backed,
    `#if`-guarded, **no `swift test`s**).
  - `CVPipeline` — concrete `CVProcessing`, constructor-injects `BallTracking` +
    `BounceDetecting` (+ frame extraction), fully testable with mocks.
  - `PostProcessingViewModel` (`@Observable`) — orchestrates the run against
    `LocalVideoStore` + `CalibrationStore` + `MatchClient`.
- **App-target SwiftUI (build-only):**
  - `CVShotReviewView` — lists detected shots with zone badges + Submit N / Discard.
  - `PostProcessingView` — progress bar + cancel.
  - `MatchSummaryView` — **updated** (it already exists on `feat/phase2-camera`) to
    show an "Analyse Video" button when a local video **and** a calibration are
    present for the match.
- **`.gitignore`:** add `cv/models/` and
  `ios/TennisShotTracker/TennisShotTracker/Resources/ML/`.

### Out of scope (non-goals)

- **Backend / DB / migrations.** `source: "cv"` reuses the existing route and column
  (§3.2). No server work, no schema change.
- **Real-time / on-camera CV.** Processing is strictly **post-recording,
  user-triggered** (v2 roadmap: real-time processing).
- **Model training or accuracy tuning.** Only the **already-validated Phase-0
  pretrained weights** are converted (CLAUDE.md: "no training in CV pipeline").
  Detection accuracy / the ≥80% correct-zone gate is a Phase-0/SPIKE concern, not
  re-litigated here.
- **`pytest` for `convert_models.py`.** Conversion touches large model weights and
  is a build-tool script; it is verified by **manual run** (§5 Python ACs), not the
  CI `pytest` suite (there is no accuracy assertion to make hermetically).
- **`out_behind` and net-event zones.** Not in the six-value enum (§3.1); deferred
  to v2, consistent with the Phase-1 gameplay spec.
- **Automatic court-line detection.** The court corners come from the **Phase-2
  manual 4-corner tap** homography; auto-detection is v2.
- **Player differentiation** (CLAUDE.md: out of scope v1). The pipeline records
  bounces regardless of which player hit the shot.
- **iOS simulator / UI tests / a CoreML-on-device test job.** The app target is
  **compile-only** (`xcodebuild build`), consistent with Slices 2 and the gameplay
  spec; the real gate is `swift test` in TennisCore.
- **Bundling the converted model files into git.** They are gitignored and copied
  manually per `cv/README.md` (§8).

## 4. Coordinate chain — pinned formula (no coder discretion)

This is the crown-jewel section. It is pinned exactly so that a **transpose bug
cannot slip through** — a transposed application would still produce
shape-valid output and pass any shape-only test silently. The chain is defined
concretely; the coder implements it verbatim.

### 4.1 Ball-pixel space — landscape 1280×720 (deviation recorded, see OQ-1)

The ball point returned by the tracker is a pixel in **1280-wide × 720-tall
landscape** space (`W = 1280`, `H = 720`), which is the Phase-0 TrackNet output
space after the `×2` post-processing:

- The ball model input tensor is `(1, 9, 360, 640)` — NCHW, so **H = 360, W = 640**
  (landscape). TrackNet emits a `640×360`-scale heatmap; the `×2` post-processing
  maps it to the original **`1280×720` landscape** frame. `640·2 = 1280` and
  `360·2 = 720` — the `×2` factor is uniform **only** under landscape (A-1). This is
  corroborated by `SPIKE_RESULT.md` (the Phase-0 `out.avi` is `1280×720`, upstream
  `yastrebksv/TennisProject`).

> **Deviation from the task's pinned fact (recorded for Gate 2, OQ-1):** the task
> pinned "720×1280 portrait, `fx = px/720`, `fy = py/1280`." That contradicts the
> two other pinned facts — a `(1,9,360,640)` tensor with a uniform `×2` can only
> produce `1280×720` **landscape**, and the Phase-0 footage is landscape. Under
> portrait the scale factors would be `720/640 ≈ 1.13` and `1280/360 ≈ 3.56` (not
> `×2`). This spec adopts **landscape 1280×720** because it is the only reading
> consistent with the model shape, the `×2` rule, and the spike. If the coder had
> instead pinned `fx = px/720`, ball-x values `> 720` would yield fractions `> 1`,
> poisoning the homography and every zone silently. See OQ-1.

### 4.2 The chain (implement verbatim)

Given a ball pixel `(px, py)` in `1280×720` landscape space and the persisted
`CourtCalibration.homographyMatrix` (9 elements, **ROW-MAJOR**,
`m = [m0,m1,m2, m3,m4,m5, m6,m7,m8]`, mapping image-fraction → court-normalized):

**Step 1 — pixel → image-fraction:**
```
fx = px / 1280      // ∈ [0,1]
fy = py / 720       // ∈ [0,1]
```

**Step 2 — apply the ROW-MAJOR homography to `(fx, fy)`:**
```
x' = m0·fx + m1·fy + m2
y' = m3·fx + m4·fy + m5
w  = m6·fx + m7·fy + m8
courtX = x' / w      // court-normalized ∈ [0,1] for in-court points
courtY = y' / w
```
The application MUST be written exactly as above (row-major, `m[3r+c]` addressing).
Applying the **transpose** — reading `m` column-major, i.e. `x' = m0·fx + m3·fy + m6`
etc. — is a defect. It is equivalent to `m[3c+r]` and would misclassify. (For
reference, the row-major array element `m[3r+c]` equals the simd column-major
matrix element `H[c][r]` that `HomographyService.compute` returns; the persisted
array is the row-major flatten — see `CalibrationStore.swift`.)

**Step 3 — court point → zone (reuse the existing classifier, do not reinvent):**
```
zone = ZoneClassifier.classify(
    point: CGPoint(x: courtX, y: courtY),
    in:    CGRect(x: 0, y: 0, width: 1, height: 1)
)
```
Feeding court-normalized coords into the unit rect reproduces the exact same
2×3 grid and six-value enum used for manual shots (`spec-ios-gameplay` §4). The
pipeline never builds a zone literal itself.

**Step 4 — package the result:**
```
CVShotResult(
    frameIndex:        <frame index — see A-6 for index semantics>,
    zone:              zone,
    normalizedCourtX:  Float(courtX),
    normalizedCourtY:  Float(courtY),
    ballPixelX:        Float(px),
    ballPixelY:        Float(py)
)
```
So `normalizedCourtX/Y == courtX/courtY` and `ballPixelX/Y == px/py` by definition.

### 4.3 Orientation invariant (must hold or zones invert — A-2, A-3)

The ball-pixel frame, the calibration `imagePoints` frame, and the recorded video
frame **are the same frame** (all derived from the one `.mov`), all `1280×720`
landscape. The calibration corner order `[TL,TR,BL,BR] → [(0,0),(1,0),(0,1),(1,1)]`
therefore fixes court-y to increase from the **top image row (net side)** to the
bottom (baseline side), which is exactly the `ZoneClassifier` row order (row 0 =
`front_court_*`). If any of these three frames disagreed in orientation or
normalization, every zone would invert while shape-only tests stayed green — hence
these are pinned as invariants (A-2) and surfaced at review, not assumed silently.

## 5. Acceptance Criteria

Each criterion is independently verifiable. **TennisCore logic ACs** are proven by
`swift test`; **app-target ACs** by `xcodebuild build` + inspection (no simulator);
**Python ACs** by a documented **manual** `convert_models.py` run (not `pytest`).
Baseline: **119 existing tests, 0 failures on `feat/phase2-camera` (verified)**.
Target: **119 + 25 new = 144+ tests, 0 failures** via `swift test` in
`ios/TennisCore`.

### Python / model conversion (manual — not in `pytest`)
- [ ] AC1: `cv/requirements.txt` pins `coremltools>=8.0`, `torch>=2.0`,
  `catboost>=1.2`, `numpy>=1.24`; `pip install -r cv/requirements.txt` succeeds in a
  clean venv.
- [ ] AC2: `python cv/convert_models.py` traces the TrackNet ball model with a
  `(1, 9, 360, 640)` example input via `torch.jit.trace`, runs `ct.convert`, and
  writes `cv/models/BallTracker.mlpackage`.
- [ ] AC3: the same run exports the CatBoost bounce model via
  `save_model(..., format='coreml')` to `cv/models/BounceDetector.mlmodel`.
- [ ] AC4: `convert_models.py` **prints the input/output tensor specs** of both
  converted models to stdout (name, shape, dtype), so the ball input shape
  `(1,9,360,640)` and the bounce input/output are visually confirmable at conversion
  time — this is the verification hook for the §4.1 landscape pin and the §7 feature
  vector (A-4).
- [ ] AC5: `cv/README.md` documents (a) obtaining the Phase-0 weights
  (`ball_track.pt`, `bounce.cbm` — see `SPIKE_RESULT.md` for the Drive IDs),
  (b) running `convert_models.py`, and (c) the **manual copy** of the two converted
  files into `ios/TennisShotTracker/TennisShotTracker/Resources/ML/`.

### TennisCore — `MockCVPipeline` / `CVProcessing` contract (`swift test`)
- [ ] AC6: `MockCVPipeline` with **zero** stubbed results returns an empty
  `[CVShotResult]` from `process(...)` and completes without error.
- [ ] AC7: `MockCVPipeline` with **N** stubbed results returns exactly those N
  results in order.
- [ ] AC8: `MockCVPipeline` with a stubbed error throws that error from
  `process(...)` (the pipeline surfaces failure rather than returning partial data).

### TennisCore — `CVPipeline` coordinate chain (`swift test`, `MockFrameExtractor` + `MockBallTracker` + `MockBounceDetector`)
These use an **asymmetric** calibration quad so a transposed homography application
would be caught (an identity/symmetric matrix satisfies `transpose(H)==H` and would
let the transpose bug pass — AC15 depends on this).
- [ ] AC9: With a fixed **asymmetric** `CourtCalibration` (non-square image quad, so
  `H != Hᵀ`), a ball pixel chosen to land in **`front_court_left`** is classified as
  `front_court_left` by `CVPipeline`. Repeat for **`front_court_right`**,
  **`baseline_left`**, **`baseline_right`**, **`out_left`**, **`out_right`** — one
  ball pixel per zone, all six passing (six assertions / cases). The ball pixels are
  given in `1280×720` space; expected zones are pinned in the test.
- [ ] AC10: In the six-zone fixture (AC9), each `CVShotResult` carries
  `ballPixelX/Y` equal to the input pixel and `normalizedCourtX/Y` equal to the
  computed `courtX/courtY` (§4.2 Step 4).
- [ ] AC11: A bounce frame whose ball point is **`nil`** (tracker returned no ball)
  is **skipped** — it produces no `CVShotResult` (a bounce with no ball location
  cannot be zoned). Given bounces `{a, b}` where frame `a` has a `nil` ball, the
  result count is 1 (only `b`).
- [ ] AC12: An **empty bounce set** (`BounceDetecting` returns `[]`) yields an
  **empty** `[CVShotResult]`, regardless of how many ball points were tracked.
- [ ] AC13: `CVPipeline.process` reports monotonic progress in `[0.0, 1.0]` via its
  progress callback and calls it at least once (the callback exists so
  `PostProcessingViewModel` can drive the progress bar).
- [ ] AC14: With `MockFrameExtractor` feeding a known frame sequence,
  `MockBallTracker` returning a known per-frame ball array, and `MockBounceDetector`
  returning a known bounce set, `CVPipeline` produces exactly one `CVShotResult` per
  (bounce frame with non-nil ball), in bounce-frame order.
- [ ] AC15: **Transpose guard (load-bearing).** In the AC9 asymmetric fixture, at
  least one of the six pinned ball pixels is chosen so that applying the homography
  **column-major (transposed)** would classify it into a *different* zone than the
  correct **row-major** application. The test asserts the row-major (correct) zone;
  a transposed implementation fails this AC. (This is why the fixture must be
  asymmetric — see A-7.)

### TennisCore — `PostProcessingViewModel` (`swift test`, injected `CVProcessing` + `StubTransport`)
- [ ] AC16: Initial `state` is `.idle`.
- [ ] AC17: `startProcessing(matchId:matchClient:)` transitions `.idle → .processing`
  and, on a `MockCVPipeline` returning N results, ends in `.done(shots)` with
  `shots.count == N`.
- [ ] AC18: When `CVProcessing` throws, the VM ends in `.failed(message)` (never
  crashes, never silently `.done`).
- [ ] AC19: On submit, the VM calls `matchClient.addShots(matchID:shots:)` with
  `shots.count == N` and **every** `ShotInput.source == "cv"` (not `"manual"`) and
  each `ShotInput.zone` equal to the corresponding `CVShotResult.zone` — verified
  against the `StubTransport`-captured request body.
- [ ] AC20: Every submitted `zone` is one of the six §3.1 strings (no `out_behind`,
  no casing drift) — property check over the submitted shots.
- [ ] AC21: A transport failure on submit surfaces as `.failed(message)` (or an
  equivalent error state) and the detected `shots` are **not lost** from the VM
  (the user can retry) — the results are retained, mirroring the gameplay spec's
  "never silently drop shots" posture (A-8).
- [ ] AC22: `dismiss()` returns `state` to `.idle`.
- [ ] AC23: `startProcessing` reads the video URL from `LocalVideoStore` and the
  calibration from `CalibrationStore` for the given `matchId`; when **either** is
  absent it does not run the pipeline and ends in `.failed` (you cannot zone without
  a homography, and cannot track without a video — A-9). Verified with two cases,
  each using an injected store pointed at a temp dir: (a) calibration file missing;
  (b) video file missing. Both branches of the guard end in `.failed`.

### TennisCore — hermetic / no-CoreML gate (`swift test`)
- [ ] AC24: The entire `swift test` suite runs and passes with **no CoreML model
  file present** on disk and **no real CoreML instantiation** — `CVPipeline`,
  `PostProcessingViewModel`, and all mocks compile and pass on macOS with the
  `#if`-guarded CoreML types excluded from the test build (§2). Total 144+ tests,
  0 failures.

### App target — build only (`xcodebuild build`, inspection)
- [ ] AC25: `xcodebuild build` of the `TennisShotTracker` app target succeeds
  (compile-only; no simulator, no test run) with the `Resources/ML/` model files
  **present** (the app target links the concrete CoreML types).
- [ ] AC26: By inspection, `MatchSummaryView` shows an **"Analyse Video"** action
  **only when** both a local video (`LocalVideoStore.exists(for:)`) and a
  calibration (`CalibrationStore.exists(for:)`) are present for the match; otherwise
  the action is hidden/disabled (A-9).
- [ ] AC27: By inspection, `PostProcessingView` renders a progress bar bound to the
  VM's `.processing(progress)` state and a cancel affordance; `CVShotReviewView`
  lists results with zone badges and offers **Submit N** and **Discard**.
- [ ] AC28: By inspection, no CV/zone/coordinate/networking logic lives in the app
  target — all of it is in TennisCore (`CVPipeline`, `PostProcessingViewModel`,
  `ZoneClassifier`, `MatchClient`); views observe the `@Observable` VM.
- [ ] AC29: By inspection, **no new third-party Swift dependency** is added to
  `Package.swift` or the app target (CoreML/AVFoundation are system frameworks; no
  SPM/CocoaPods addition).

## 6. API Contract (consumed as delivered — no new endpoint)

No new endpoint and no change to any existing one. The pipeline reuses exactly one
route, already delivered and verified on `feat/phase2-camera`:

| Method & path | Request body | Success body |
|---|---|---|
| `POST /matches/{id}/shots` | `{"shots":[{"zone":"…","source":"cv"},…]}` | `{"count":N}` |

The **only** difference from the manual flow is `source: "cv"` in each `ShotInput`.
Auth (`Authorization: Bearer <token>`), error shape (`{"error":"…"}`), and status
mapping are inherited unchanged from `MatchClient` (see `spec-ios-gameplay` §6). The
backend is the authority for the accepted zone set and `source` value; it stores
what the client sends.

## 7. Functional Requirements

### CV Pipeline (Python) — `cv/`

- **CV-1:** `cv/requirements.txt` pins the four dependencies in AC1.
- **CV-2:** `cv/convert_models.py` loads the Phase-0 TrackNet ball weights, calls
  `torch.jit.trace` with an example input of shape `(1, 9, 360, 640)`, runs
  `coremltools.convert`, and writes `cv/models/BallTracker.mlpackage`.
- **CV-3:** the same script loads the Phase-0 CatBoost bounce model and calls
  `model.save_model("cv/models/BounceDetector.mlmodel", format="coreml")`.
- **CV-4:** the script prints both models' input/output specs to stdout (AC4).
- **CV-5:** `cv/README.md` is the setup + manual-copy doc (AC5); `cv/models/` and the
  iOS `Resources/ML/` dir are gitignored (§8). `convert_models.py` is **not** part of
  the `pytest` suite (out of scope; §3).

### iOS (Swift) — TennisCore `CV/`

- **FR-C1 — `CVShotResult`:** `public struct` with
  `frameIndex: Int`, `zone: String`, `normalizedCourtX: Float`,
  `normalizedCourtY: Float`, `ballPixelX: Float`, `ballPixelY: Float`.
  Pure value type, no CoreML import — `swift test`-visible.
- **FR-C2 — `CVProcessing` protocol:** the single seam the VM depends on, e.g.
  `func process(videoURL: URL, calibration: CourtCalibration, progress: (Double) -> Void) async throws -> [CVShotResult]`.
  (Exact signature is an implementation detail so long as it takes the video +
  calibration and yields `[CVShotResult]` with a progress hook — FR-C7/AC13.)
- **FR-C3 — `MockCVPipeline`:** concrete `CVProcessing` test double with
  `stubbedResults: [CVShotResult]` and `stubbedError: Error?`; throws the error if
  set, else returns the results (AC6–AC8).
- **FR-C4 — `FrameExtracting` protocol + `FrameExtractor` + `MockFrameExtractor`:**
  `func extractFrames(from url: URL, every stride: Int) -> [(index: Int, pixelBuffer: CVPixelBuffer)]`
  (or an `async`/throwing equivalent). `FrameExtractor` is AVFoundation-backed and
  **`#if`-guarded** so it is excluded from the macOS test build. Because `CVPipeline`
  injects `FrameExtracting` (FR-C7) and the concrete extractor is guarded out of the
  test build, a **`MockFrameExtractor`** (unguarded — `CVPixelBuffer` is CoreVideo
  and compiles on macOS) is required so `CVPipeline`'s coordinate-chain tests
  (AC9/AC14) can feed a known frame sequence. Frame-index semantics are pinned by A-6.
- **FR-C5 — `BallTracking` protocol + `BallTrackerInference`:** the concrete type
  loads `BallTracker.mlpackage`, runs the model, and applies the Phase-0
  post-processing **in Swift** — `argmax → threshold → centroid → ×2` — returning
  `[(x: Float, y: Float)?]` (one optional ball point per input frame, `nil` when no
  ball). `#if`-guarded for macOS compile; it **has no `swift test`s** (it cannot init
  without the model file — that is expected and acceptable per §2). The `×2` scaling
  reproduces Phase-0 TrackNet post-processing and bakes in the `1280×720` landscape
  output space (§4.1, A-1).
- **FR-C6 — `BounceDetecting` protocol + `BounceDetectorInference`:** the concrete
  type loads `BounceDetector.mlmodel`, builds a **12-column** feature
  `MLMultiArray` per candidate frame, runs the model, applies a **0.45** probability
  threshold, and returns `Set<Int>` (the set of bounce frame indices). `#if`-guarded;
  **no `swift test`s**. The exact 12-feature column order is **not yet pinned in
  source available on this branch** and is called out as **OQ-2 / A-4**: the Phase-0
  CatBoost training code is the byte-for-byte authority for the order, and
  `convert_models.py`'s printed spec (AC4) is the confirmation hook. A wrong column
  order produces garbage with all shape-tests green — hence it is surfaced, not
  guessed.
- **FR-C7 — `CVPipeline`:** concrete `CVProcessing` that **constructor-injects**
  `BallTracking` + `BounceDetecting` (+ `FrameExtracting`) so it is fully testable
  with mocks. It runs: extract frames → track balls → detect bounces → **for each
  bounce frame with a non-nil ball point**, apply the §4.2 coordinate chain →
  `ZoneClassifier` zone → `CVShotResult`. Bounces with a `nil` ball are skipped
  (AC11); an empty bounce set yields `[]` (AC12); it reports progress (AC13). It
  imports **only** the protocols and `ZoneClassifier`/`CourtCalibration` — never the
  concrete CoreML types — so it compiles and tests on macOS (§2, AC24).
- **FR-C8 — `PostProcessingViewModel` (`@Observable`):** holds a `ProcessingState`
  enum `idle | processing(progress: Double) | done(shots: [CVShotResult]) | failed(message: String)`;
  injects a `CVProcessing`. `startProcessing(matchId:matchClient:)` resolves the
  video URL from `LocalVideoStore` and the calibration from `CalibrationStore`,
  fails fast with `.failed` if either is missing (AC23), runs
  `CVProcessing.process` with the progress callback driving `.processing(progress)`,
  then holds `.done(shots)`. Submitting calls
  `matchClient.addShots(matchID: matchId, shots: shots.map { ShotInput(zone: $0.zone, source: "cv") })`
  (AC19). **Cancel is `dismiss()` → `.idle`** — there is no separate `.cancelled`
  case in `ProcessingState`; cancelling an in-flight run returns to `.idle` and
  discards any partial results. `dismiss()` returns to `.idle` (AC22). Detected shots
  are retained on a submit transport failure (AC21). Lives in TennisCore so it is `swift test`-able
  (A-5, mirrors the gameplay spec's `@Observable`-in-core precedent).

### iOS (Swift) — app target

- **FR-V1 — `MatchSummaryView` (updated):** adds an **"Analyse Video"** action,
  visible only when `LocalVideoStore.exists(for: matchId)` **and**
  `CalibrationStore.exists(for: matchId)` are both true (AC26, A-9); tapping it
  presents `PostProcessingView`.
- **FR-V2 — `PostProcessingView`:** observes `PostProcessingViewModel`; shows a
  progress bar bound to `.processing(progress)` and a cancel affordance; on `.done`
  routes to `CVShotReviewView`; on `.failed` shows the message with a retry.
- **FR-V3 — `CVShotReviewView`:** lists the `[CVShotResult]` with a zone badge per
  row and offers **Submit N** (calls the VM submit → `addShots` with `source: "cv"`)
  and **Discard** (VM `dismiss()`).
- **FR-V4 — no testable logic in the app target** (AC28): views are thin readers of
  the `@Observable` VM; all CV/zone/coordinate/networking logic is in TennisCore.

### Backend (Go)
- N/A for this phase. `source: "cv"` reuses the existing `POST /matches/{id}/shots`
  route and the existing `record.source` column (§3.2, §6). No server work, no
  migration.

## 8. Data Model Changes

**None.** No database and no schema changes. The `record` table already has a
`source` column (Phase 1) that accepts the string the client sends; `source = 'cv'`
is a **value**, not a schema change. The load-bearing data facts:

- Each `cv` shot is a `record` row with `source = 'cv'` and a `zone` from the six
  §3.1 values — produced by `ZoneClassifier` (§4.2 Step 3), never a literal.
- The homography and video are **on-device files only** (Phase-2 `CalibrationStore`
  `calibrations/{matchId}.json` and `LocalVideoStore` `videos/{matchId}.mov`); no CV
  artifact is persisted server-side.

### Gitignore additions
```
cv/models/
ios/TennisShotTracker/TennisShotTracker/Resources/ML/
```
Both directories hold large binary model files that are produced by
`convert_models.py` and copied manually per `cv/README.md`; neither is committed.

## 9. Non-Functional Requirements

### Configuration / secrets
- No new config, no secrets, no `.env`. Reuses the Phase-2 injectable base URL and
  Keychain-stored JWT via `MatchClient`. The Phase-0 model weights are downloaded
  out-of-band (Drive IDs in `SPIKE_RESULT.md`), never committed.

### Security / privacy
- CV runs **on-device only** (CLAUDE.md locked decision: "On-device only (v1) —
  Privacy, offline"). The `.mov` and homography never leave the device; only the
  derived six-value zone strings are submitted, over the existing authenticated
  route (`Authorization: Bearer <token>`).

### Performance
- **No latency target this phase.** Processing is offline/post-recording and
  user-triggered; `SPIKE_RESULT.md` measured ball detection ≈ 3 it/s on CPU (~70 s /
  220 frames) and explicitly deferred on-device speed to a **separate later gate**.
  A `FrameExtracting.every` stride is provided so the coder can sub-sample frames
  (default stride is OQ-3), but throughput is not gated here.

### Known technical risk (carried forward)
- No iOS simulator runtime and a hand-authored `.xcodeproj`; the app target is
  **compile-only** (`xcodebuild build`). The real gate is `swift test` in TennisCore
  (§10). The CoreML-backed types are never exercised in CI (§2); their correctness
  is validated manually on-device and via the Phase-0 spike, not by this suite.
- **Bounce detection is unconfirmed on real footage** (`SPIKE_RESULT.md` Step 1: 0
  bounces on the degraded smoke clip; Steps 2 & 3 blocked on footage). This phase
  wires the pipeline through assuming the Phase-0 models work; if real footage yields
  ~0 bounces, that is a Phase-0/model issue surfaced there, not a defect in this
  wiring (A-10).

## 10. Verification Gates (verbatim)

- `swift test` in `ios/TennisCore` passes — **the real test gate**.
  **119 existing + 25 new = 144+ tests, 0 failures**, with **no CoreML model file
  present** (hermetic, §2 / AC24).
- Zone strings emitted match the six-value backend enum **byte-for-byte**
  (`front_court_left/right`, `baseline_left/right`, `out_left/right`; no
  `out_behind`) — AC20.
- `xcodebuild build` of the app target succeeds (compile-only; no simulator), with
  the `Resources/ML/` model files present — AC25.
- `python cv/convert_models.py` is verified by a **manual** run producing
  `BallTracker.mlpackage` + `BounceDetector.mlmodel` and printing I/O specs — AC2–AC4
  (not part of `pytest`/CI).
- Branch is `feat/phase3-cv` (based on `origin/main`/`bdec000`, §2b); the PR targets
  `main`, is labeled `ai-generated`, and is **never merged autonomously** — Gate 2
  human review.

## 11. Open Questions

Gate 1 is pre-approved, so each carries a recommended default the coder follows
unless the human overrides it.

- **OQ-1 — Ball-pixel coordinate space: landscape vs the task's pinned portrait
  (load-bearing).** The task pinned "720×1280 portrait, `fx = px/720`,
  `fy = py/1280`." That is **internally inconsistent** with the two other pinned
  facts: a `(1,9,360,640)` model tensor plus a **uniform `×2`** post-processing can
  only produce **`1280×720` landscape** (`640·2=1280`, `360·2=720`), and the Phase-0
  footage is landscape (`SPIKE_RESULT.md`, `out.avi` `1280×720`). Portrait would
  require non-uniform scale factors (`1.13` and `3.56`). **Default (adopted in §4):
  `1280×720` landscape, `fx = px/1280`, `fy = py/720`.** This spec flips the pinned
  denominator because primary-source evidence (model shape + `×2` + spike) breaks
  toward landscape; a portrait pin would silently poison every zone. Confirm at
  Gate 1, and confirm Phase-2 capture: `CameraService` sets **no `sessionPreset`
  and no orientation** (uses the AVCaptureSession default → landscape-native buffers)
  — the recorded `.mov` resolution is therefore **not pinned in Phase 2**. If Phase 2
  is later changed to force portrait or a non-`1280×720` preset, the `×2` scaling and
  both `fx/fy` denominators change **together** and this section must be revisited.
- **OQ-2 — Bounce detector 12-feature column order (load-bearing).** `FR-C6`
  assembles a 12-column feature vector, but the exact order is not derivable from any
  source on this branch and `BounceDetectorInference` has **no `swift test`** to
  guard it — a wrong order yields garbage with all shape-tests green. **Default:**
  the coder MUST reproduce the **Phase-0 CatBoost training feature order
  byte-for-byte** (the training/inference code that produced `bounce.cbm` is the
  authority) and confirm it against `convert_models.py`'s printed input spec (AC4).
  Pin the order in `cv/README.md` when recovered. Confirm the authority source, or
  provide the ordered feature list directly.
- **OQ-3 — Frame-extraction stride.** `FrameExtracting.extractFrames(from:every:)`
  sub-samples frames. **Default: `every: 1`** (process every frame — matches Phase-0
  which tracks per-frame and the bounce model expecting a continuous trajectory;
  `SPIKE_RESULT.md` warns a fragmented track suppresses bounce detection). Confirm,
  or specify a stride for speed (would trade off bounce recall — coupled to OQ-2's
  trajectory-continuity need).
- **OQ-4 — Bounce probability threshold.** **Default: `0.45`** (as pinned in the
  task / FR-C6). Confirm, or tune once real footage is available (a Phase-0 accuracy
  concern; not gated here).
- **OQ-5 — Submit-all vs per-shot selection in the review screen.** `CVShotReviewView`
  offers Submit N / Discard. **Default: submit all N detected shots in one
  `addShots` batch** (no per-row deselect this phase). Confirm, or specify per-shot
  include/exclude (a small view-layer + VM change, flagged).
- **OQ-6 — Re-analysis / duplicate shots.** Nothing prevents the user tapping
  "Analyse Video" twice and submitting the same bounces again (the backend appends).
  **Default: no dedup this phase** — re-analysis appends new `cv` rows; the user is
  responsible. Confirm, or specify a guard (e.g. disable "Analyse Video" once `cv`
  shots exist for the match — would need a `listShots` check, flagged).

## 12. Assumptions

Where the inputs are silent or self-contradictory, these are the explicit
assumptions so the coder has no undocumented decision. Any of these the human can
override.

- **A-1 — Landscape `1280×720` ball-pixel space.** The `×2` post-processing on a
  `(1,9,360,640)` (H=360,W=640) model maps to `1280×720` landscape uniformly; the
  Phase-0 footage is landscape. `fx = px/1280`, `fy = py/720` (§4.1, OQ-1). A
  portrait pin is rejected as inconsistent with the model shape and the `×2` rule.
- **A-2 — Single shared frame / orientation invariant.** The ball-pixel frame, the
  calibration `imagePoints` frame, and the recorded video frame are the **same**
  `1280×720` landscape frame (all from one `.mov`); a mismatch inverts zones (§4.3).
- **A-3 — Calibration corner order fixes court-y direction.**
  `[TL,TR,BL,BR]→[(0,0),(1,0),(0,1),(1,1)]` means court-y increases net→baseline, so
  reusing `ZoneClassifier`'s row order (row 0 = `front_court_*`) is correct only if
  TL/TR are the **net-side** corners. Stated so an inversion surfaces at review.
- **A-4 — Bounce feature order deferred to Phase-0 authority.** The 12-column vector
  order is taken byte-for-byte from the Phase-0 CatBoost code, not guessed (OQ-2).
- **A-5 — VMs live in TennisCore.** `PostProcessingViewModel` is `@Observable` in
  TennisCore so it is `swift test`-able, per the gameplay-spec precedent; the SwiftUI
  views are thin readers. CLAUDE.md's `ViewModels/` layout note is superseded by this
  testability constraint, consistent with prior slices.
- **A-6 — `CVShotResult.frameIndex` = original-video frame number.** With a frame
  stride (OQ-3), `frameIndex` is the index in the **original video** (stride applied),
  not the position in the extracted subsequence — so it is a stable reference into the
  source `.mov`. With the default stride `1` the two coincide. Pinned to avoid an
  ambiguous index.
- **A-7 — Six-zone tests use an asymmetric calibration.** The AC9/AC15 fixture uses a
  non-square image quad so `H != Hᵀ`; a symmetric/identity matrix would let a
  transposed application pass and defeat the transpose guard (§4.2).
- **A-8 — Detected shots never silently dropped.** On a submit transport failure the
  VM retains `shots` and surfaces `.failed` for retry (AC21), mirroring the
  gameplay-spec "never drop shots" posture.
- **A-9 — Calibration + video both required to analyse.** Without a homography there
  is no way to zone a ball point; "Analyse Video" is gated on both files existing
  (AC26) and `startProcessing` fails fast if either is missing (AC23).
- **A-10 — Phase-0 model efficacy is out of scope.** This phase wires the pipeline
  assuming the converted Phase-0 models detect bounces/balls; `SPIKE_RESULT.md` notes
  bounce detection is still unconfirmed on real footage. A ~0-bounce result on real
  footage is a Phase-0/model finding, not a defect in this wiring.
- **A-11 — No new Swift dependency.** CoreML and AVFoundation are system frameworks;
  the pipeline adds no SPM/CocoaPods package (AC29).

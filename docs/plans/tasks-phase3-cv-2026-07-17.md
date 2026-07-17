# Tasks: CV Integration — On-Device CoreML Post-Processing (Phase 3)

**Plan:** `docs/plans/plan-phase3-cv-2026-07-17.md`
**Spec:** `docs/specs/spec-phase3-cv-2026-07-17.md` (Gate-1 approved)
**Total tasks:** 12
**Branch:** `feat/phase3-cv` off `origin/main` (`bdec000`, spec §2b RESOLVED). PR targets `main`, labeled `ai-generated`, never merged autonomously. All work confined to `cv/`, `ios/`, `.gitignore`, and these docs. Never touch anything outside `tennis-tracker/`.

> **Order (6 groups, dependency-driven, per the task's grouping):**
> **(1) Python `cv/` + `.gitignore`** (Tasks 1–2) → **(2) TennisCore CV value types + protocols + mocks** (Tasks 3–4) → **(3) `CVPipeline` coordinate chain** (Task 5, crown jewel) → **(4) `PostProcessingViewModel`** (Task 6) → **GATE CHECKPOINT (`swift test` green, 144+)** → **(5) `#if`-guarded CoreML/AVFoundation inference classes** (Tasks 7–9, no swift tests) → **(6) app-target SwiftUI views + composition root + xcodeproj** (Tasks 10–11) → **final gate** (Task 12).
>
> Tasks 3–6 make `swift test` green at **144+** — the real gate (spec §10, AC24, hermetic / no CoreML file). Groups 5–6 are build-only and MUST NOT require editing or re-running the logic tests. Python (group 1) is independent and verified by a **manual** `convert_models.py` run, not `pytest`.
>
> **Conventions:** SwiftUI + MVVM; `PostProcessingViewModel` is `@Observable` and IN TennisCore (A-5); async/await for all I/O (no completion handlers); **XCTest** (not swift-testing); conventional commits. `#if` guard for CoreML/AVFoundation concrete types is **`#if !os(macOS)`** (NOT `#if canImport(CoreML)` — CoreML canImports on macOS and would break the hermetic gate). Ball-pixel space is **landscape `1280×720`**, `fx=px/1280`, `fy=py/720` (OQ-1 RESOLVED). Coordinate application is the **literal row-major array formula** (`m[3r+c]`) — NEVER reconstruct a `simd_float3x3`, NEVER reuse `HomographyService`'s `H*columnVector`. Each task is one coder pass (≤ ~200 lines new code). **Migration rule (never combine migration + app code) is N/A — no migration, no backend this phase.**
>
> **The six OQ defaults are LOCKED (plan §0 header): OQ-1=landscape 1280×720, OQ-3=stride 1, OQ-4=0.45 threshold, OQ-5=submit-all, OQ-6=no-dedup. OQ-2 (12-column CatBoost feature order) is an UNRESOLVED task-level RISK — recovered from Phase-0 code byte-for-byte, not guessed (Task 9).**

---

## Task 1: `.gitignore` + `cv/requirements.txt` + `cv/README.md`
**Layer:** cv (Python) + repo config
**Files to create/modify:**
- `.gitignore` — append the two lines `cv/models/` and `ios/TennisShotTracker/TennisShotTracker/Resources/ML/` (spec §8). Do not remove existing entries.
- `cv/requirements.txt` — pin exactly: `coremltools>=8.0`, `torch>=2.0`, `catboost>=1.2`, `numpy>=1.24` (AC1 / CV-1).
- `cv/README.md` — document (a) obtaining the Phase-0 weights `ball_track.pt` + `bounce.cbm` (Drive IDs in `SPIKE_RESULT.md`), (b) running `python cv/convert_models.py`, (c) the **manual copy** of `BallTracker.mlpackage` + `BounceDetector.mlmodel` into `ios/TennisShotTracker/TennisShotTracker/Resources/ML/`, (d) a placeholder section "12-column CatBoost bounce feature order" to be filled in Task 9 once recovered (OQ-2). (AC5 / CV-5.)
- Create the `cv/models/` directory with a `.gitkeep` **only if** needed to keep the (gitignored) path documented — otherwise leave the README to describe it. Do not commit any model binary.
**Depends on:** none
**Acceptance (AC1, AC5):** `pip install -r cv/requirements.txt` succeeds in a clean venv (the four pins resolve); `.gitignore` contains both new paths; `cv/README.md` covers the weight-fetch, conversion, manual-copy, and feature-order-placeholder sections.
**Test:** manual — `pip install -r cv/requirements.txt` in a fresh venv exits 0; `git check-ignore cv/models/x` and `git check-ignore ios/TennisShotTracker/TennisShotTracker/Resources/ML/x` both report the path ignored. Not part of `pytest`/`swift test`.

## Task 2: `cv/convert_models.py` (manual conversion script)
**Layer:** cv (Python) — manual run, NOT pytest
**Files to create/modify:**
- `cv/convert_models.py` — per plan §3.1 / CV-2..CV-4:
  - Load the Phase-0 TrackNet ball weights (`cv/models/ball_track.pt`), build an example input of shape **`(1, 9, 360, 640)`**, `torch.jit.trace` the model, `coremltools.convert(...)`, write `cv/models/BallTracker.mlpackage` (AC2).
  - Load the Phase-0 CatBoost bounce model (`cv/models/bounce.cbm`) and `model.save_model("cv/models/BounceDetector.mlmodel", format="coreml")` (AC3).
  - **Print both models' input/output tensor specs** (name, shape, dtype) to stdout (AC4) — the confirmation hook for the §5.1 landscape pin (ball input `(1,9,360,640)`) and the OQ-2 bounce feature order (Task 9).
  - Type hints required (CLAUDE.md); `ruff`-clean.
**Depends on:** Task 1 (requirements + models dir)
**Acceptance (AC2–AC4):** a manual `python cv/convert_models.py` (with the two Phase-0 weights present in `cv/models/`) writes `BallTracker.mlpackage` + `BounceDetector.mlmodel` under `cv/models/` and prints the I/O specs of both.
**Test:** manual run only (out of scope for `pytest`, §3). The coder documents the printed specs in the PR / `cv/README.md`. No CI assertion.

## Task 3: `CVShotResult` + `CVProcessing` + `MockCVPipeline` + contract tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/CVShotResult.swift` — per plan §3.2.1: `public struct CVShotResult: Equatable { public let frameIndex: Int; public let zone: String; public let normalizedCourtX: Float; public let normalizedCourtY: Float; public let ballPixelX: Float; public let ballPixelY: Float; public init(...) }`. Imports **only `Foundation`** — no CoreML/AVFoundation (swift-test-visible). Explicit `public init` (synthesized memberwise is internal for a public struct). `frameIndex` = ORIGINAL-video frame number (A-6).
- `ios/TennisCore/Sources/TennisCore/CV/CVProcessing.swift` — per plan §3.2.2: `public protocol CVProcessing { func process(videoURL: URL, calibration: CourtCalibration, progress: @escaping (Double) -> Void) async throws -> [CVShotResult] }`. Add a small `public enum CVPipelineError: Error, Equatable` for pipeline-internal failures if needed. `progress` is a plain escaping (non-`@Sendable`) closure invoked inline. Imports `Foundation`.
- `ios/TennisCore/Sources/TennisCore/CV/MockCVPipeline.swift` — **in `Sources/`, NOT `Tests/`** (shippable — VM previews + VM tests; mirrors `MockCameraService`). `public final class MockCVPipeline: CVProcessing { public var stubbedResults: [CVShotResult] = []; public var stubbedError: Error?; public init() }`. `process(...)`: if `stubbedError != nil` → `throw` it (AC8); else call `progress(0.0)` then `progress(1.0)` and return `stubbedResults` in order (AC6/AC7).
- `ios/TennisCore/Tests/TennisCoreTests/MockCVPipelineTests.swift`.
**Depends on:** none (uses only the existing `CourtCalibration` on `main`)
**Acceptance (AC6–AC8):** `MockCVPipeline` with 0 stubbed results returns `[]` and does not throw (AC6); with N stubbed results returns exactly those N in order (AC7); with a stubbed error throws that error (AC8).
**Test:** `swift test`: (AC6) empty `stubbedResults` → `process` returns `[]`; (AC7) N results → returns the same N in order; (AC8) `stubbedError` set → `process` throws it (assert the thrown error identity).

## Task 4: Three worker protocols (`FrameExtracting`/`BallTracking`/`BounceDetecting`) + their `Tests/` mocks
**Layer:** ios (TennisCore) — `swift test` (protocols + mocks; concrete impls come in Tasks 7–9)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/FrameExtracting.swift` — per plan §3.2.4: `import CoreVideo`; `public protocol FrameExtracting { func extractFrames(from url: URL, every stride: Int) async throws -> [(index: Int, pixelBuffer: CVPixelBuffer)] }`. `index` is the ORIGINAL-video frame index, stride applied (A-6). Must compile on macOS (CoreVideo is available).
- `ios/TennisCore/Sources/TennisCore/CV/BallTracking.swift` — `import CoreVideo`; `public protocol BallTracking { func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?] }`. One optional per input frame, same order; `nil` = no ball (AC11); points in `1280×720` landscape (§5.1).
- `ios/TennisCore/Sources/TennisCore/CV/BounceDetecting.swift` — `public protocol BounceDetecting { func detectBounces(ballPoints: [(index: Int, point: (x: Float, y: Float)?)]) async throws -> Set<Int> }`. Takes the indexed ball trajectory (NOT raw frames) because CatBoost features derive from the trajectory (plan §3.2.6 note). Returns the set of ORIGINAL-video bounce frame indices.
- `ios/TennisCore/Tests/TennisCoreTests/MockFrameExtractor.swift` — unguarded test double returning a caller-set `[(index: Int, pixelBuffer: CVPixelBuffer)]`. (`CVPixelBuffer` compiles on macOS — create buffers via `CVPixelBufferCreate` in the test setup.)
- `ios/TennisCore/Tests/TennisCoreTests/MockBallTracker.swift` — returns a caller-set `[(x,y)?]` (known per-frame points incl. `nil`s).
- `ios/TennisCore/Tests/TennisCoreTests/MockBounceDetector.swift` — returns a caller-set `Set<Int>`.
**Depends on:** none (protocols are standalone; mocks live in Tests/)
**Acceptance:** all three protocols + mocks compile under `swift test` on macOS (CoreVideo available; no CoreML/AVFoundation import). The mocks return their configured values. (No standalone ACs — these are consumed by Task 5; a tiny compile/roundtrip test per mock is optional and counts toward the tally only if the budget needs it. The plan's budget does NOT count these, keeping 25 exactly.)
**Test:** `swift test`: the suite still compiles and is green with the three protocols + three mocks present (they are exercised for real in Task 5). Optionally a trivial "mock returns configured value" test each.

## Task 5: `CVPipeline` (concrete `CVProcessing`) + coordinate-chain / transpose-guard tests  *(CROWN JEWEL)*
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/CVPipeline.swift` — per plan §3.2.7 / FR-C7. `public final class CVPipeline: CVProcessing`. `import Foundation`, `import CoreGraphics` (for `CGPoint`/`CGRect` into `ZoneClassifier`). **Imports ONLY the protocols + `ZoneClassifier` + `CourtCalibration` — NEVER the concrete CoreML/AVFoundation types** (§2, AC24). `public init(frameExtractor: FrameExtracting, ballTracker: BallTracking, bounceDetector: BounceDetecting, stride: Int = 1)` (OQ-3 default 1). `process(videoURL:calibration:progress:)`:
  1. `progress(0.0)`.
  2. `frames = try await frameExtractor.extractFrames(from: videoURL, every: stride)`.
  3. `balls = try await ballTracker.track(frames: frames.map(\.pixelBuffer))` — index-aligned to `frames`; report progress.
  4. `bounceSet = try await bounceDetector.detectBounces(ballPoints: <zip frames.index with balls>)`; report progress.
  5. For each `frame` with `frame.index ∈ bounceSet` **and** a non-nil ball point (nil-ball bounce skipped — AC11): apply the **§5.2 coordinate chain VERBATIM** — `fx = px/1280`, `fy = py/720`; `x' = m0·fx+m1·fy+m2`, `y' = m3·fx+m4·fy+m5`, `w = m6·fx+m7·fy+m8`; `courtX = x'/w`, `courtY = y'/w` over `calibration.homographyMatrix` (row-major `[Float]`, `m[3r+c]`). **DO NOT reconstruct a `simd_float3x3`; DO NOT reuse `HomographyService`.** Then `zone = ZoneClassifier.classify(point: CGPoint(x: courtX, y: courtY), in: CGRect(x:0,y:0,width:1,height:1))`; build `CVShotResult(frameIndex: frame.index, zone:, normalizedCourtX: Float(courtX), normalizedCourtY: Float(courtY), ballPixelX: px, ballPixelY: py)`.
  6. Emit in bounce-frame order (AC14); empty `bounceSet` → `[]` (AC12); `progress(1.0)`.
- `ios/TennisCore/Tests/TennisCoreTests/CVPipelineTests.swift` — uses `MockFrameExtractor` + `MockBallTracker` + `MockBounceDetector` from Task 4, and an **asymmetric** `CourtCalibration` fixture built via `HomographyService.compute` over a non-square image quad + the unit square, flattened through the shared `CourtCalibration(homography:)` init (§5.4).
**Depends on:** Task 3 (`CVShotResult`, `CVProcessing`), Task 4 (three protocols + mocks). Uses existing `ZoneClassifier`, `HomographyService`, `CourtCalibration` on `main`.
**Acceptance (AC9–AC15):** with the asymmetric fixture, one ball pixel per zone maps to the pinned zone for all six zones (AC9); each `CVShotResult` carries `ballPixelX/Y == input px/py` and `normalizedCourtX/Y == computed courtX/courtY` (AC10); a bounce whose ball is `nil` is skipped, `{a(nil),b}` → count 1 (AC11); empty bounce set → `[]` regardless of tracked balls (AC12); progress is monotonic in [0,1] and called ≥1 (AC13); with known frames/balls/bounces, exactly one result per (bounce frame with non-nil ball) in bounce-frame order (AC14); the transpose guard holds (AC15).
**Test (CRITICAL — the transpose guard; the test-writer MUST honor §5.4):**
- **AC9 six-zone fixture:** build the calibration from an **asymmetric FRACTION-SPACE image quad** via `HomographyService.compute(imagePoints:, courtPoints: unitSquare)` → `CourtCalibration(homography:)`. **The quad MUST be in `[0,1]` fraction space, e.g. `[(0.1,0.1),(0.9,0.15),(0.05,0.9),(0.95,0.85)]` in `[TL,TR,BL,BR]`** — asymmetric so `H != Hᵀ` (A-7). **Do NOT copy the Phase-2 pixel-valued quad (`(100,50),(1920,50),…`)** — production's persisted `H` maps image-fraction→court (`tapCorner` converts px→fraction *before* `compute`), and the pipeline feeds fractions (`fx=px/1280`); a pixel-valued quad builds an `H` that collapses every court point near the origin and the six zones cannot be spread (plan §5.4). Pin six ball pixels in `1280×720` space, one per zone (`front_court_left/right`, `baseline_left/right`, `out_left/right`), and assert the pipeline classifies each into the expected zone. **6 tests.**
- **AC15 transpose guard (load-bearing — DEDICATED distinct test, a 7th fixture case, NOT folded into the six):** pin one additional ball pixel chosen so that applying the homography **column-major (transposed, `x'=m0·fx+m3·fy+m6…`)** classifies it into a *different* zone than the correct row-major application. Assert the **row-major** zone. A transposed implementation fails this case. (Compute both zones off-line when authoring the fixture to confirm the pixel actually diverges — pick it deliberately.) **1 test.** Keeping AC15 as its own case is what makes Task 5 = 12 tests (6 + AC10/11/12/13/14 = 5 + AC15 = 1); folding it in would drop the count to 11 and miss the 144 gate.
- **AC10:** for the six results, assert `ballPixelX/Y == input` and `normalizedCourtX/Y == courtX/courtY` (recompute the row-major chain in the test to derive expected court coords).
- **AC11:** bounces `{a,b}`, frame `a`'s ball `nil` → result count 1 (only `b`).
- **AC12:** `MockBounceDetector` returns `[]` → `process` returns `[]` even with non-nil balls tracked.
- **AC13:** capture progress values in a closure; assert non-decreasing, all in [0,1], ≥1 call, final `1.0`.
- **AC14:** known frames + balls + bounce set → exactly one result per (bounce frame, non-nil ball), order matches bounce-frame order.

## Task 6: `PostProcessingViewModel` (`@Observable`) + VM tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/PostProcessingViewModel.swift` — per plan §3.2.8 / FR-C8. `import Foundation`, `import Observation`. `public enum ProcessingState: Equatable { case idle; case processing(progress: Double); case done(shots: [CVShotResult]); case failed(message: String) }` — **NO `.cancelled`** (cancel = `dismiss()` → `.idle`). `@Observable public final class PostProcessingViewModel`. `public private(set) var state: ProcessingState = .idle` (AC16). `public init(pipeline: CVProcessing, videoStore: LocalVideoStore = LocalVideoStore(), calibrationStore: CalibrationStore = CalibrationStore())` — `pipeline` injected at init; stores injectable for AC23 temp-dir isolation. Methods:
  - `startProcessing(matchId:matchClient:) async` — resolve `videoStore.videoURL(for:)` + require `videoStore.exists(for:)`; `calibrationStore.load(for:)`. **If video absent OR calibration nil → `.failed(message:)`, do NOT run the pipeline** (AC23). Else `.processing(0.0)` (AC17); `try await pipeline.process(videoURL:calibration:progress:)` with `progress` setting `.processing(progress)` (AC13/AC27); success → `.done(shots:)` (AC17); any throw → `.failed(message:)` (AC18). Retain `shots` in a private stored property (for AC21 retry).
  - `submit(matchId:matchClient:) async` — from `.done(shots)`: `matchClient.addShots(matchID: matchId, shots: shots.map { ShotInput(zone: $0.zone, source: "cv") })` (AC19). On transport failure → `.failed(message:)` **and retain `shots`** so the VM can re-enter `.done` for retry (AC21).
  - `dismiss()` — `state = .idle`; discards partial results (also the cancel affordance) (AC22).
- `ios/TennisCore/Tests/TennisCoreTests/PostProcessingViewModelTests.swift` — inject `MockCVPipeline` + a `MatchClient` built on `StubTransport` (existing helper) + temp-dir `LocalVideoStore`/`CalibrationStore`; clean up in `tearDown`. For AC23, seed a real video/calibration file in the temp dir for the happy path, and omit one for each guard case.
**Depends on:** Task 3 (`MockCVPipeline`, `CVProcessing`, `CVShotResult`). Uses existing `MatchClient`, `ShotInput`, `LocalVideoStore`, `CalibrationStore`, `StubTransport` on `main`.
**Acceptance (AC16–AC23):** initial `.idle` (AC16); `MockCVPipeline` returning N → `.idle→.processing→.done(shots)` with `shots.count==N` (AC17); pipeline throws → `.failed` (never `.done`, never crash) (AC18); submit calls `addShots` with `shots.count==N`, **every `source=="cv"`**, each `zone` == the corresponding `CVShotResult.zone`, verified against the `StubTransport`-captured body (AC19); every submitted `zone` is one of the six §3.1 strings (AC20); submit transport failure → `.failed`, shots retained (AC21); `dismiss()` → `.idle` (AC22); missing video OR missing calibration → `.failed`, pipeline not run — two cases via temp-dir stores (AC23).
**Test:** `swift test` with `MockCVPipeline` + `StubTransport`-backed `MatchClient` + temp-dir stores: one test per AC16–AC22, plus the two AC23 guard cases. For AC19/AC20 decode `StubTransport.capturedRequest?.httpBody` and assert the `shots` array `source`/`zone` values. Temp dirs cleaned in `tearDown` (no real `~/Documents` writes).

> **GATE CHECKPOINT (after Task 6):** `cd ios/TennisCore && swift test` must be fully green with **25 new tests on top of the existing 119 (144 total)** — the slice's real gate (spec §10, AC24, hermetic / no CoreML file present). Budget: 3 (Task 3) + 12 (Task 5: 6 zone + AC10/11/12/13/14/15) + 10 (Task 6: AC16–22 = 8, AC23 = 2) = **25 new → 144 total** ✅. Tasks 7–11 add build-only `#if`-guarded impls + UI and must not require re-running or editing logic tests; Task 12 re-confirms `swift test` still green.

## Task 7: `FrameExtractor` (AVFoundation, `#if !os(macOS)`) — build-only
**Layer:** ios (TennisCore) — build-only (excluded from macOS `swift test`)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/FrameExtractor.swift` — **entirely wrapped in `#if !os(macOS)`** (mirrors `CameraService`). `import AVFoundation`. `public final class FrameExtractor: FrameExtracting`. Reads frames from the `.mov` at `url` via `AVAssetImageGenerator`/`AVAssetReader`, taking every `stride`-th frame, returning `[(index: Int, pixelBuffer: CVPixelBuffer)]` where `index` is the ORIGINAL-video frame number (stride applied — A-6). Build-only; **no `swift test`**.
**Depends on:** Task 4 (`FrameExtracting` protocol)
**Acceptance:** by inspection + build — the file is `#if !os(macOS)`-guarded and excluded from the macOS test build (`swift test` still green without it); it conforms to `FrameExtracting`; `index` is the original-video frame index. Compiled in Task 11.
**Test:** none runnable (build-only). Verification is inspection + the Task 11 build. `swift test` must remain green (proves the guard excludes it).

## Task 8: `BallTrackerInference` (CoreML, `#if !os(macOS)`) — build-only, no tests
**Layer:** ios (TennisCore) — build-only
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/BallTrackerInference.swift` — **entirely `#if !os(macOS)`**. `import CoreML`, `import CoreVideo`. `public final class BallTrackerInference: BallTracking`. Loads `BallTracker.mlpackage` at **runtime** via `Bundle.main.url(forResource: "BallTracker", withExtension: "mlpackage"/"mlmodelc")` + `MLModel(contentsOf:)` (NOT Xcode-generated model classes — plan §3.4). `track(frames:)`: runs the model per input tensor and applies the Phase-0 post-processing **in Swift** — `argmax → threshold → centroid → ×2` — returning `[(x,y)?]` in `1280×720` landscape space (the `×2` bakes in the landscape output, §5.1 / A-1); `nil` when no ball. Build-only; **no `swift test`** (cannot init without the model file — expected, §2).
**Depends on:** Task 4 (`BallTracking` protocol)
**Acceptance:** by inspection + build — `#if !os(macOS)`-guarded, excluded from the macOS test build; conforms to `BallTracking`; loads the model via `MLModel(contentsOf:)` at runtime (no codegen dependency); applies `argmax→threshold→centroid→×2` yielding `1280×720` points. Compiled in Task 11.
**Test:** none runnable (build-only, no model file in CI). Inspection against FR-C5 + §3.4. `swift test` remains green (guard excludes it).

## Task 9: `BounceDetectorInference` (CoreML, `#if !os(macOS)`) — build-only, no tests  *(OQ-2 RISK)*
**Layer:** ios (TennisCore) — build-only
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/CV/BounceDetectorInference.swift` — **entirely `#if !os(macOS)`**. `import CoreML`. `public final class BounceDetectorInference: BounceDetecting`. Loads `BounceDetector.mlmodel` at **runtime** via `Bundle.main.url(...)` + `MLModel(contentsOf:)`. `detectBounces(ballPoints:)`: builds a **12-column** feature `MLMultiArray` per candidate frame in the **Phase-0 CatBoost column order**, runs the model, applies the **`0.45`** probability threshold (OQ-4), returns `Set<Int>`. Build-only; **no `swift test`**.
- `cv/README.md` — fill in the "12-column CatBoost bounce feature order" section with the recovered byte-for-byte order (Task 1 placeholder).
**Depends on:** Task 4 (`BounceDetecting` protocol), Task 2 (`convert_models.py` printed spec confirms the order — AC4)
**Acceptance:** by inspection + build — `#if !os(macOS)`-guarded, excluded from the macOS test build; conforms to `BounceDetecting`; runtime model load; 12-column feature vector in the **recovered Phase-0 order**; `0.45` threshold. Compiled in Task 11.
> **RISK (load-bearing — OQ-2 / A-4):** the 12-column feature order is NOT derivable from any source on this branch and this file has **no `swift test`** to guard it — a wrong order yields garbage with all shape-tests green. The coder MUST recover the order **byte-for-byte from the Phase-0 CatBoost training/inference code that produced `bounce.cbm`** (the authority), confirm it against `convert_models.py`'s printed input spec (AC4), record it in `cv/README.md`, and **NOT guess**. If the Phase-0 code is unavailable, STOP and surface it — do not proceed with a guessed order.
**Test:** none runnable (build-only, no model file in CI). Inspection against FR-C6 + the recovered order documented in `cv/README.md`. `swift test` remains green (guard excludes it).

## Task 10: `PostProcessingView` + `CVShotReviewView` — build-only
**Layer:** ios (app target) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/PostProcessingView.swift` — per plan §3.3/FR-V2: observes `PostProcessingViewModel`; on appear `await vm.startProcessing(matchId:matchClient:)`; a progress bar bound to `.processing(progress)`; a **cancel** affordance calling `vm.dismiss()`; on `.done` routes to `CVShotReviewView`; on `.failed` shows the message + a retry. Thin reader — no CV/coordinate/networking logic. `init(vm: PostProcessingViewModel, matchClient: MatchClient, matchID: String)`.
- `ios/TennisShotTracker/TennisShotTracker/Views/CVShotReviewView.swift` — per plan §3.3/FR-V3: lists `[CVShotResult]` (from `.done(shots)`) with a **zone badge per row**; **Submit N** → `vm.submit(matchId:matchClient:)` (→ `addShots` with `source:"cv"`); **Discard** → `vm.dismiss()`. OQ-5: submit all N in one batch, no per-row deselect. Thin reader. `init(vm: PostProcessingViewModel, matchClient: MatchClient, matchID: String, shots: [CVShotResult])`.
**Depends on:** Task 6 (`PostProcessingViewModel`, `ProcessingState`, `CVShotResult`)
**Acceptance (AC27, AC28):** by inspection — `PostProcessingView` renders a progress bar bound to `.processing(progress)` + a cancel affordance; `CVShotReviewView` lists results with zone badges + Submit N / Discard; **no CV/zone/coordinate/networking logic in either view** (all via the VM). Compiled in Task 11.
**Test:** none runnable (build-only). Inspection against FR-V2/FR-V3 + AC27/AC28.

## Task 11: `MatchSummaryView` update + CV composition root + wire views into `.xcodeproj` + build
**Layer:** ios (app target / project file) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchSummaryView.swift` — per plan §3.3/§3.4/FR-V1: add an **"Analyse Video"** action visible/enabled **only when** both `LocalVideoStore().exists(for: matchID)` **and** `CalibrationStore().exists(for: matchID)` are true (AC26, A-9); otherwise hidden/disabled. This view is the **composition root**: construct the concrete `CVPipeline(frameExtractor: FrameExtractor(), ballTracker: BallTrackerInference(), bounceDetector: BounceDetectorInference())` + `PostProcessingViewModel(pipeline:videoStore:calibrationStore:)` and navigate to `PostProcessingView(vm:matchClient:matchID:)`. Keep the existing summary grid unchanged. No CV/coordinate logic in the view (AC28).
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add `PostProcessingView.swift` + `CVShotReviewView.swift` to the app-target Sources build phase; add `Resources/ML/` as an app-target resource folder reference so the manually-copied `.mlpackage`/`.mlmodel` bundle at build time (precondition for AC25, not built here). No change to the TennisCore package reference.
**Depends on:** Task 10 (the two views exist), Tasks 7–9 (concrete `#if`-guarded types exist for the composition root — iOS-only, so only compiled in the app/iOS build).
**Acceptance (AC25, AC26, AC28, AC29):**
```
xcodebuild build \
  -project ios/TennisShotTracker/TennisShotTracker.xcodeproj \
  -scheme TennisShotTracker \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```
succeeds (compile-only) **with the `Resources/ML/` model files present** (AC25). **If the iOS destination is unresolvable (no simulator runtime — known env reality),** fall back to the Phase-1/2 `swiftc -typecheck` compensator over the app-target sources against the iOS-built `TennisCore` module (`-sdk iphoneos -target arm64-apple-ios17.0`); **record which path was used for Gate 2.** A build-env failure is NOT a code defect. By inspection: "Analyse Video" is gated on video+calibration (AC26); no CV/zone/coord/net logic in the app target (AC28); no new dependency added to `Package.swift` or the app target (AC29).
**Test:** the `xcodebuild build` command exits 0 (or the type-check compensator exits 0, deviation recorded). No simulator run; no `swift test` dependency.

## Task 12: Final gate pass
**Layer:** ios (verification)
**Files to create/modify:** none (verification + any last fixes surfaced by the gates).
**Depends on:** Task 6 (`swift test` green) and Task 11 (build/typecheck green)
**Acceptance (spec §10):**
1. `cd ios/TennisCore && swift test` → all TennisCore tests pass, **25 new / 144 total**, with **no CoreML model file present** (the real gate; AC6–AC23, hermetic AC24). Record the exact new/total count.
2. Zone strings emitted are the six §3.1 values byte-for-byte (produced by `ZoneClassifier`, AC20) — no `out_behind`, no casing drift.
3. `xcodebuild build` (Task 11 command) → exit 0 with `Resources/ML/` present (AC25), OR the type-check compensator exits 0 with the deviation recorded (env-blocked).
4. By inspection: the three `#if !os(macOS)` inference/extractor files (`FrameExtractor`, `BallTrackerInference`, `BounceDetectorInference`) are excluded from the macOS test build; `swift test` passes without them (AC24). AC26 (Analyse Video gating), AC27 (progress bar + cancel; review list + Submit N/Discard), AC28 (no logic in app target), AC29 (no new dependency) hold.
5. OQ-2: the recovered 12-column CatBoost feature order is documented in `cv/README.md` and confirmed against `convert_models.py`'s printed spec (AC4). If it could not be recovered, this is surfaced as a Gate-2 blocker, not silently guessed.
Deferred and explicitly NOT gated this phase: iOS simulator/UI tests, iOS CI job, live CoreML on-device inference, `pytest` for `convert_models.py`, model-file bundling in git (§ non-goals). The `xcodebuild build` env-block is a **known deferred Gate-2 item, not a task failure**.
**Test:** run `swift test` + the build/typecheck command; confirm green. Record which ACs each command proves and the new/total test count. Then run `/ponytail-review` on the diff (global CLAUDE.md) and address or annotate any flags.

---

## AC → Task coverage matrix

| AC | Task(s) |
|---|---|
| AC1 (requirements.txt pins) | 1 |
| AC2 (TrackNet → BallTracker.mlpackage) | 2 |
| AC3 (CatBoost → BounceDetector.mlmodel) | 2 |
| AC4 (prints I/O specs — OQ-2 hook) | 2 (used by 9) |
| AC5 (README setup + manual copy) | 1 (feature order filled in 9) |
| AC6 (Mock 0 → empty) | 3 |
| AC7 (Mock N → N in order) | 3 |
| AC8 (Mock error → throws) | 3 |
| AC9 (six-zone asymmetric fixture) | 5 |
| AC10 (ballPixel/normalizedCourt fields) | 5 |
| AC11 (nil-ball bounce skipped) | 5 |
| AC12 (empty bounce set → []) | 5 |
| AC13 (monotonic progress ≥1 call) | 5 (also 6 via VM) |
| AC14 (one result per non-nil-ball bounce, in order) | 5 |
| AC15 (transpose guard) | 5 |
| AC16 (initial .idle) | 6 |
| AC17 (.idle→.processing→.done N) | 6 |
| AC18 (throw → .failed) | 6 |
| AC19 (submit: N shots, all source "cv", zones match) | 6 |
| AC20 (every zone one of six) | 6 |
| AC21 (submit failure → .failed, shots retained) | 6 |
| AC22 (dismiss → .idle) | 6 |
| AC23 (missing video OR calibration → .failed, two cases) | 6 |
| AC24 (hermetic, 144+, no CoreML file) | 3–6 (guards in 7–9), 12 |
| AC25 (xcodebuild build w/ models present) | 11, 12 |
| AC26 (Analyse Video gated on video+calibration) | 11 |
| AC27 (progress bar + cancel; review Submit N/Discard) | 10 |
| AC28 (no logic in app target) | 10, 11 |
| AC29 (no new dependency) | 11, 12 |

Every AC1–AC29 maps to at least one task. The hermetic gate (AC24) is proven by Tasks 3–6 compiling + passing on macOS with the Task 7–9 `#if !os(macOS)` types excluded and no model file present. OQ-2 (Task 9) is surfaced as a task-level risk with the Phase-0 code as authority. No orphans.

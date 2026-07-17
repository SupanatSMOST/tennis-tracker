# Plan: CV Integration — On-Device CoreML Post-Processing (Phase 3)

**Spec:** `docs/specs/spec-phase3-cv-2026-07-17.md` (Gate-1 approved)
**Date:** 2026-07-17
**Author:** architect (AI)
**Branch:** `feat/phase3-cv` off `origin/main` (`bdec000`, spec §2b RESOLVED). PR targets `main`, labeled `ai-generated`, never merged autonomously (Gate 2). All work confined to `cv/`, `ios/`, `.gitignore`, and these docs. Never touch anything outside `tennis-tracker/`.

> **Gate-1 OQ defaults LOCKED (spec §11 — the coder does NOT re-open them):**
> - **OQ-1 (ball-pixel coordinate space):** **RESOLVED — landscape `1280×720`**, human-confirmed (§4.1). `fx = px/1280`, `fy = py/720`. Ignore the spec's portrait-vs-landscape narrative — that is the spec-analyst's settled history, not a live decision.
> - **OQ-2 (12-column CatBoost feature order):** **UNRESOLVED task-level RISK, not a pin.** Authority is the Phase-0 CatBoost training code **byte-for-byte**; confirmation hook is `convert_models.py`'s printed input spec (AC4). The coder MUST recover it, record it in `cv/README.md`, and NOT guess — see §9. It lives in a `#if`-guarded, untested file (`BounceDetectorInference`), so a wrong order passes every `swift test` green.
> - **OQ-3 (frame stride):** **`every: 1`** (process every frame — Phase-0 tracks per-frame; a fragmented track suppresses bounce detection).
> - **OQ-4 (bounce probability threshold):** **`0.45`**.
> - **OQ-5 (review submit):** **submit all N in one `addShots` batch** — no per-row deselect this phase.
> - **OQ-6 (re-analysis / dedup):** **no dedup** — re-analysis appends new `cv` rows; user's responsibility.

---

## 0. Non-goals (carried forward from spec §3 "Out of scope")

Explicitly **not** built this phase:
- **No backend / DB / migration.** `source: "cv"` reuses the existing `POST /matches/{id}/shots` route and the existing `record.source` column (spec §3.2, §6, §8). `ShotInput(zone:source:)` and `MatchClient.addShots(matchID:shots:)` already exist and are verified on `main` — **no new DTO, no `MatchClient` change** (confirmed: `Models/MatchModels.swift` `ShotInput.init(zone:source:)` and `Gameplay/MatchClient.swift` `addShots`).
- **No real-time / on-camera CV.** Strictly post-recording, user-triggered.
- **No model training or accuracy tuning.** Only the already-validated Phase-0 pretrained weights are converted (CLAUDE.md: "no training in CV pipeline"). The ≥80% correct-zone gate is a Phase-0/SPIKE concern (A-10).
- **No `pytest` for `convert_models.py`.** It is a manual build-tool script verified by a documented run producing the two model files + printed I/O specs (AC2–AC4). There is no accuracy assertion to make hermetically.
- **No `out_behind` / net-event zones.** Not in the six-value enum (§3.1); deferred to v2. The six strings come solely from reusing `ZoneClassifier` — the pipeline never builds a zone literal.
- **No automatic court-line detection.** Corners come from the Phase-2 manual 4-corner tap homography.
- **No player differentiation** (CLAUDE.md v1 out of scope).
- **No iOS simulator / UI tests / CoreML-on-device CI job.** The app target is **compile-only** (`xcodebuild build`); the real gate is `swift test` in TennisCore. The CoreML-backed types are never exercised in CI (§2 / AC24); their correctness is validated manually on-device and via the Phase-0 spike.
- **No bundling of converted model files into git.** `cv/models/` and `ios/.../Resources/ML/` are gitignored (§8); files are copied manually per `cv/README.md`.
- **No new third-party Swift dependency** (AC29). CoreML, AVFoundation, CoreVideo, CoreGraphics, Observation are system frameworks — no SPM/CocoaPods addition.

## 1. Architecture Overview

This phase wires the proven Phase-0 CV pipeline into the iOS app as **on-device CoreML post-processing**, triggered from the match detail screen after a match is recorded, with **zero backend change** and **all CV / coordinate / zone / networking logic in TennisCore** so it is provable by `swift test` (the real gate; `xcodebuild build` is env-blocked and compile-only). The central architectural constraint is that **CoreML lives entirely outside the testable layer**: every model-backed type sits behind a Swift protocol and is `#if !os(macOS)`-guarded so it does not compile into — and is not required by — the macOS `swift test` build (§2, AC24). The orchestrating `CVPipeline` and `PostProcessingViewModel` depend **only on the protocols** and are fully testable with mocks, with no model file present on disk.

The crown-jewel correctness risk is the **coordinate chain (§4 of the spec, §5 here)**: a transposed homography application produces shape-valid output and passes any shape-only test silently. The plan pins the application as the **literal scalar array formula over the persisted row-major `[Float]`** (`m[3r+c]` addressing) and **forbids reconstructing a `simd_float3x3` or reusing `HomographyService`'s `H * columnVector` forward map** — re-indexing the array into simd columns is exactly where the transpose re-enters. This is guarded by an **asymmetric-quad fixture (AC9/AC15)** in which at least one ball pixel resolves to a *different* zone under row-major vs column-major application, so a transposed implementation fails the suite (§5.4, §9).

Around the pipeline sit: value types (`CVShotResult`), four seams (`CVProcessing`, `FrameExtracting`, `BallTracking`, `BounceDetecting`), their mocks, a concrete `CVPipeline` (constructor-injects the three worker seams), a concrete `PostProcessingViewModel` (`@Observable`, injects `CVProcessing` + the Phase-2 `LocalVideoStore`/`CalibrationStore`, takes `MatchClient` per call), the three `#if`-guarded CoreML/AVFoundation inference classes (no `swift test`s), and three thin app-target SwiftUI surfaces (`MatchSummaryView` updated, `PostProcessingView`, `CVShotReviewView`). A Python `cv/` build-tool directory converts the two Phase-0 weights to CoreML via a **manual** `convert_models.py` run.

### Environment reality (stated, carried from Phase 2, not fixed here)

There is **no iOS simulator runtime on the build machine**. `swift test` in `ios/TennisCore` is the **real gate** (baseline **119 green** on `main`, verified; target **144+** = 25+ new, 0 failures, with **no CoreML model file present** — hermetic, §2 / AC24). App-target and `#if`-guarded files are **build-only** (`xcodebuild build`, or the Phase-1/2 `swiftc -typecheck` compensator if the iOS destination is unresolvable); a build-env failure is a **known deferred Gate-2 item, not a task failure** (§10). A build-env failure never blocks the green TennisCore work.

## 2. Critical Architectural Constraint — the hermetic CoreML boundary (spec §2, non-negotiable)

| Layer | Where | `#if` guard | `swift test`? |
|---|---|---|---|
| `CVShotResult` (value type) | `Sources/.../CV/` | none | yes |
| `CVProcessing` / `FrameExtracting` / `BallTracking` / `BounceDetecting` (protocols) | `Sources/.../CV/` | none | yes (compile + used by pipeline tests) |
| `MockCVPipeline` | `Sources/.../CV/` (shippable — VM previews) | none | yes |
| `MockFrameExtractor` / `MockBallTracker` / `MockBounceDetector` | `Tests/TennisCoreTests/` | none | yes |
| `CVPipeline` (concrete `CVProcessing`) | `Sources/.../CV/` | none | yes (with mocks) |
| `PostProcessingViewModel` (`@Observable`) | `Sources/.../CV/` | none | yes (with `MockCVPipeline` + temp-dir stores) |
| `FrameExtractor` (AVFoundation) | `Sources/.../CV/` | **`#if !os(macOS)`** | no (build-only) |
| `BallTrackerInference` (CoreML) | `Sources/.../CV/` | **`#if !os(macOS)`** | no (build-only) |
| `BounceDetectorInference` (CoreML) | `Sources/.../CV/` | **`#if !os(macOS)`** | no (build-only) |
| `MatchSummaryView` (updated) / `PostProcessingView` / `CVShotReviewView` | app target | — | no (build-only) |

**The guard is `#if !os(macOS)` — NOT `#if canImport(CoreML)`.** CoreML `canImport`s on macOS; a `canImport(CoreML)` guard would pull the inference types into the hermetic macOS test build and break AC24. This mirrors the shipped `Camera/CameraService.swift` precedent exactly (`#if !os(macOS)`).

**Consequences (enforced by this plan):**
- `swift test` never instantiates a real CoreML model and never reads a `.mlpackage`/`.mlmodel`. The model files are gitignored (§8) and absent in CI; the testable layer compiles and passes with them absent (AC24).
- Zone classification stays **on-device and client-owned** — the pipeline maps a ball point to a court point and feeds it into the **existing** `ZoneClassifier.classify(point:in:)` against `CGRect(0,0,1,1)` (confirmed: `Gameplay/ZoneClassifier.swift`, six strings, net at minY). It never invents a taxonomy.
- `source: "cv"` needs **no backend change, no client-model change** — the pipeline / VM builds `ShotInput(zone: z, source: "cv")` and submits through the existing `addShots` (§4).

## 3. Component Design

### 3.1 CV Pipeline (Python) — `cv/` (new directory, build-tool only)

**New files:**
```
cv/
├── requirements.txt      # coremltools>=8.0, torch>=2.0, catboost>=1.2, numpy>=1.24 (AC1)
├── convert_models.py     # manual conversion script (AC2–AC4) — NOT pytest
├── README.md             # setup + manual-copy doc (AC5)
└── models/               # GITIGNORED — source weights + converted packages (§8)
```

- `convert_models.py` (CV-2..CV-4):
  - Loads the Phase-0 TrackNet ball weights (`ball_track.pt`), traces with an example input of shape **`(1, 9, 360, 640)`** via `torch.jit.trace`, runs `coremltools.convert`, writes `cv/models/BallTracker.mlpackage` (AC2).
  - Loads the Phase-0 CatBoost bounce model (`bounce.cbm`) and calls `save_model("cv/models/BounceDetector.mlmodel", format="coreml")` (AC3).
  - **Prints both models' input/output tensor specs** (name, shape, dtype) to stdout so the ball input `(1,9,360,640)` and the bounce input/output are visually confirmable at conversion time (AC4) — this is the verification hook for the §5.1 landscape pin and, critically, the **OQ-2 bounce feature order** (§9).
  - Run **manually** (`python cv/convert_models.py`); not in `pytest`, not in CI (CV-5).
- `cv/README.md` documents (a) obtaining the Phase-0 weights (`ball_track.pt`, `bounce.cbm` — Drive IDs in `SPIKE_RESULT.md`), (b) running `convert_models.py`, (c) the **manual copy** of the two converted files into `ios/TennisShotTracker/TennisShotTracker/Resources/ML/`, and (d) the **recovered 12-column CatBoost feature order** once the coder pins it against AC4 (§9).

### 3.2 iOS (Swift) — `ios/TennisCore` package — testable seams + pipeline + VM

**New files (all in `Sources/TennisCore/CV/`):**
```
ios/TennisCore/Sources/TennisCore/CV/
├── CVShotResult.swift            # value type (FR-C1) — swift test
├── CVProcessing.swift            # protocol + CVPipelineError (FR-C2) — swift test
├── MockCVPipeline.swift          # test double, shippable (FR-C3) — swift test
├── FrameExtracting.swift         # protocol (FR-C4) — swift test (compiles on macOS)
├── BallTracking.swift            # protocol (FR-C5) — swift test
├── BounceDetecting.swift         # protocol (FR-C6) — swift test
├── CVPipeline.swift              # concrete CVProcessing (FR-C7) — swift test with mocks
├── PostProcessingViewModel.swift # @Observable (FR-C8) — swift test
├── FrameExtractor.swift          # AVFoundation concrete, #if !os(macOS) — BUILD-ONLY
├── BallTrackerInference.swift    # CoreML concrete, #if !os(macOS) — BUILD-ONLY, no tests
└── BounceDetectorInference.swift # CoreML concrete, #if !os(macOS) — BUILD-ONLY, no tests
```

**New test-only mocks (in `Tests/TennisCoreTests/`):**
```
ios/TennisCore/Tests/TennisCoreTests/
├── MockFrameExtractor.swift   # unguarded — CVPixelBuffer is CoreVideo, compiles on macOS
├── MockBallTracker.swift
└── MockBounceDetector.swift
```

**No modified TennisCore files.** `Package.swift` is untouched (AC29). CoreML / AVFoundation / CoreVideo / CoreGraphics / Observation are system frameworks; no `dependencies:` change.

#### 3.2.1 `CV/CVShotResult.swift` (FR-C1 — pinned value type)

```swift
import Foundation   // no CoreML/AVFoundation import — swift-test-visible

public struct CVShotResult: Equatable {
    public let frameIndex: Int          // ORIGINAL-video frame number (A-6; stride applied)
    public let zone: String             // one of the six §3.1 strings (from ZoneClassifier)
    public let normalizedCourtX: Float  // == courtX from §5.2 Step 2
    public let normalizedCourtY: Float
    public let ballPixelX: Float        // == input px
    public let ballPixelY: Float        // == input py

    public init(frameIndex: Int, zone: String,
                normalizedCourtX: Float, normalizedCourtY: Float,
                ballPixelX: Float, ballPixelY: Float)
}
```
Explicit `public init` (the synthesized memberwise init is `internal` for a `public` struct — mirrors `CGPointCodable`).

#### 3.2.2 `CV/CVProcessing.swift` (FR-C2 — the single VM-facing seam, pinned)

```swift
import Foundation

public protocol CVProcessing {
    /// Runs the full pipeline over the video, mapping bounces to zoned shots.
    /// `progress` is invoked with a monotonic value in [0,1] (AC13).
    func process(
        videoURL: URL,
        calibration: CourtCalibration,
        progress: @escaping (Double) -> Void
    ) async throws -> [CVShotResult]
}
```
- `progress` is a **non-`@Sendable`** escaping closure; `process` is `async` but the pipeline invokes `progress` inline (not across an actor hop) so no `Sendable` annotation is required. `PostProcessingViewModel` passes a closure that mutates its `state` on the caller's context (the VM drives the run from its own `startProcessing`).
- Failure surfaces by **throwing** (AC8) — the pipeline never returns partial data on error.

#### 3.2.3 `CV/MockCVPipeline.swift` (FR-C3 — shippable test double, in `Sources/`)

```swift
public final class MockCVPipeline: CVProcessing {
    public var stubbedResults: [CVShotResult] = []
    public var stubbedError: Error?
    public init()
    // process(...): if stubbedError != nil -> throw it (AC8);
    //   else call progress(0.0), progress(1.0), return stubbedResults in order (AC6/AC7/AC13).
}
```
In `Sources/` (not `Tests/`) because the VM's SwiftUI previews and the `PostProcessingViewModel` tests both use it — mirrors the shipped `MockCameraService` precedent.

#### 3.2.4 `CV/FrameExtracting.swift` (FR-C4) + `Tests/MockFrameExtractor.swift` + `CV/FrameExtractor.swift`

```swift
import CoreVideo   // CVPixelBuffer — compiles on macOS

public protocol FrameExtracting {
    /// Extracts frames from `url`, taking every `stride`-th frame.
    /// `index` is the ORIGINAL-video frame index (stride applied), not the
    /// position in the returned subsequence (A-6).
    func extractFrames(from url: URL, every stride: Int) async throws
        -> [(index: Int, pixelBuffer: CVPixelBuffer)]
}
```
- **`MockFrameExtractor`** (in `Tests/`, unguarded): returns a caller-configured `[(index: Int, pixelBuffer: CVPixelBuffer)]`. `CVPixelBuffer` is CoreVideo and compiles on macOS, so the pipeline's coordinate-chain tests (AC9/AC14) can feed a known frame sequence without the concrete AVFoundation extractor.
- **`FrameExtractor`** (in `Sources/`, `#if !os(macOS)`): AVFoundation-backed concrete implementation reading frames from the `.mov`. Build-only; no `swift test`.

#### 3.2.5 `CV/BallTracking.swift` (FR-C5) + `Tests/MockBallTracker.swift` + `CV/BallTrackerInference.swift`

```swift
public protocol BallTracking {
    /// One optional ball point per input frame, in the same order as `frames`.
    /// `nil` when no ball was detected in that frame (AC11).
    /// Points are in 1280×720 landscape pixel space (§5.1).
    func track(frames: [CVPixelBuffer]) async throws -> [(x: Float, y: Float)?]
}
```
- **`MockBallTracker`** (in `Tests/`): returns a caller-configured `[(x,y)?]` array (known per-frame ball points incl. `nil`s).
- **`BallTrackerInference`** (in `Sources/`, `#if !os(macOS)`, **no `swift test`s**): loads `BallTracker.mlpackage` at runtime via `Bundle.url(forResource:withExtension:)` + `MLModel(contentsOf:)` (NOT Xcode-generated model classes — see §3.4 loading note), runs the model, and applies the Phase-0 post-processing **in Swift**: `argmax → threshold → centroid → ×2`, returning `[(x,y)?]` in `1280×720` landscape space. The `×2` bakes in the landscape output space (§5.1, A-1). Cannot init without the model file — that is expected and acceptable (§2).

#### 3.2.6 `CV/BounceDetecting.swift` (FR-C6) + `Tests/MockBounceDetector.swift` + `CV/BounceDetectorInference.swift`

```swift
public protocol BounceDetecting {
    /// The set of frame indices (ORIGINAL-video, matching FrameExtracting.index)
    /// at which a bounce was detected. Empty set -> no shots (AC12).
    func detectBounces(ballPoints: [(index: Int, point: (x: Float, y: Float)?)]) async throws -> Set<Int>
}
```
- **`MockBounceDetector`** (in `Tests/`): returns a caller-configured `Set<Int>`.
- **`BounceDetectorInference`** (in `Sources/`, `#if !os(macOS)`, **no `swift test`s**): loads `BounceDetector.mlmodel` at runtime, builds a **12-column** feature `MLMultiArray` per candidate frame in the **Phase-0 CatBoost column order (OQ-2 — RISK, recovered not guessed, §9)**, runs the model, applies the **`0.45`** probability threshold (OQ-4), returns `Set<Int>`. A wrong column order produces garbage with all shape-tests green — see §9.

> **Signature note (pinned to remove the FR-C6 ambiguity):** `BounceDetecting` takes the per-frame ball points (index + optional point) rather than raw frames, because the CatBoost bounce features are derived from the **ball trajectory**, not the pixels. `CVPipeline` (§3.2.7) tracks balls first, then hands the indexed trajectory to the detector. This keeps the detector testable via `MockBounceDetector` returning a known `Set<Int>` and matches the Phase-0 flow (track → trajectory features → bounce).

#### 3.2.7 `CV/CVPipeline.swift` (FR-C7 — concrete `CVProcessing`, the crown-jewel path)

```swift
import Foundation
import CoreGraphics   // CGPoint / CGRect for ZoneClassifier

public final class CVPipeline: CVProcessing {
    public init(
        frameExtractor: FrameExtracting,
        ballTracker: BallTracking,
        bounceDetector: BounceDetecting,
        stride: Int = 1                 // OQ-3 default
    )
    public func process(videoURL:calibration:progress:) async throws -> [CVShotResult]
}
```
Imports **only** the protocols + `ZoneClassifier` + `CourtCalibration` — **never** the concrete CoreML/AVFoundation types (§2, AC24). Algorithm (pinned, no coder discretion):
1. `progress(0.0)`.
2. `frames = try await frameExtractor.extractFrames(from: videoURL, every: stride)`.
3. `balls = try await ballTracker.track(frames: frames.map { $0.pixelBuffer })` — one optional per frame, index-aligned to `frames`. Report progress.
4. `bounceSet = try await bounceDetector.detectBounces(ballPoints: zip(frames.indices ...))` — pass the indexed `(index, point)` trajectory (§3.2.6 note). Report progress.
5. For each `frame` whose `index ∈ bounceSet` **and** whose ball point is **non-nil** (a `nil`-ball bounce is skipped — AC11): apply the **§5.2 coordinate chain verbatim** → `courtX/courtY` → `ZoneClassifier.classify(point: CGPoint(x: courtX, y: courtY), in: CGRect(0,0,1,1))` → build `CVShotResult(frameIndex: index, zone:, normalizedCourtX: Float(courtX), normalizedCourtY: Float(courtY), ballPixelX: px, ballPixelY: py)`.
6. Emit results in **bounce-frame order** (AC14). Empty `bounceSet` → `[]` (AC12). `progress(1.0)`.

#### 3.2.8 `CV/PostProcessingViewModel.swift` (FR-C8 — `@Observable`, pinned)

```swift
import Foundation
import Observation

public enum ProcessingState: Equatable {
    case idle
    case processing(progress: Double)
    case done(shots: [CVShotResult])
    case failed(message: String)
    // NO .cancelled — cancel == dismiss() -> .idle (FR-C8)
}

@Observable
public final class PostProcessingViewModel {
    public private(set) var state: ProcessingState = .idle   // AC16

    public init(
        pipeline: CVProcessing,
        videoStore: LocalVideoStore = LocalVideoStore(),
        calibrationStore: CalibrationStore = CalibrationStore()
    )

    public func startProcessing(matchId: String, matchClient: MatchClient) async
    public func submit(matchId: String, matchClient: MatchClient) async
    public func dismiss()   // -> .idle (AC22)
}
```
- `pipeline` injected at **init**; `matchClient` passed **per call** (mirrors `RecordSessionViewModel(client:matchID:)` DI, but the CV VM is created before a match is chosen so the client comes per-call). `videoStore`/`calibrationStore` injectable via `baseDirectory` for AC23's two temp-dir cases (mirrors the Phase-2 store-test isolation).
- `startProcessing(matchId:matchClient:)` (pinned):
  1. Resolve `videoURL = videoStore.videoURL(for: matchId)` and require `videoStore.exists(for: matchId)`; resolve `calibration = calibrationStore.load(for: matchId)`. **If the video file is absent OR the calibration is nil → `.failed(message:)`, do NOT run the pipeline** (AC23; two branches). You cannot track without a video nor zone without a homography (A-9).
  2. `.idle → .processing(0.0)` (AC17).
  3. `results = try await pipeline.process(videoURL:calibration:progress:)`, the `progress` closure setting `state = .processing(progress)` (drives AC13/AC27 progress bar). Monotonic in [0,1].
  4. Success → `.done(shots: results)` with `shots.count == N` (AC17).
  5. Any thrown error → `.failed(message:)` — never crashes, never silently `.done` (AC18).
- `submit(matchId:matchClient:)` (pinned): only valid from `.done(shots)`. Calls
  `matchClient.addShots(matchID: matchId, shots: shots.map { ShotInput(zone: $0.zone, source: "cv") })` (AC19). **Every `ShotInput.source == "cv"`** and each `zone` equals the corresponding `CVShotResult.zone` (AC19/AC20). On a transport failure → `.failed(message:)` **and the detected `shots` are retained** (held in a private stored property so the VM can re-enter `.done` for retry — AC21, mirroring the gameplay "never drop shots" posture, A-8).
- `dismiss()` → `.idle`; also the **cancel** affordance (discards any partial results; no `.cancelled` case — FR-C8, AC22).

### 3.3 iOS (Swift) — `TennisShotTracker` app target (thin, build-only)

**New files:**
```
ios/TennisShotTracker/TennisShotTracker/Views/
├── PostProcessingView.swift   # progress bar bound to .processing + cancel (FR-V2)
└── CVShotReviewView.swift      # zone-badge list + Submit N / Discard (FR-V3)
```

**Modified files (build-only):**
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchSummaryView.swift` — add the **"Analyse Video"** action + nav (FR-V1); the CV composition root (§3.4).
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add the two new view files to the app-target Sources build phase; ensure `Resources/ML/` is referenced as a resource folder for the app target (so the manually-copied models bundle at build time — precondition, not built here).

**View responsibilities (all thin — no CV/zone/coordinate/networking logic in the app target, AC28):**
- **`MatchSummaryView` (updated, FR-V1):** adds an "Analyse Video" action visible/enabled **only when** both `LocalVideoStore.exists(for: matchID)` **and** `CalibrationStore.exists(for: matchID)` are true (AC26, A-9); otherwise hidden/disabled. Tapping it navigates to `PostProcessingView`. This is the **composition root** for the concrete pipeline (§3.4).
- **`PostProcessingView` (FR-V2):** observes `PostProcessingViewModel`; on appear `await vm.startProcessing(matchId:matchClient:)`; shows a progress bar bound to `.processing(progress)` and a cancel affordance (`vm.dismiss()`); on `.done` routes to `CVShotReviewView`; on `.failed` shows the message + retry.
- **`CVShotReviewView` (FR-V3):** lists the `[CVShotResult]` (from `.done(shots)`) with a **zone badge per row**; **Submit N** calls `vm.submit(matchId:matchClient:)` (→ `addShots` with `source:"cv"`); **Discard** calls `vm.dismiss()`. OQ-5: submit all N in one batch, no per-row deselect.

### 3.4 CV composition root + model loading (build-only, pinned — the Phase-3 wiring seam)

`MatchSummaryView` is the composition root because it is the only place with the `matchID` and access to the app-target-only concrete types. Pinned wiring:
- `MatchSummaryView` constructs the stores it needs for the AC26 gate and for the VM: `let videoStore = LocalVideoStore()`, `let calibrationStore = CalibrationStore()` (default Documents dir in the app; TennisCore types).
- The **concrete `CVPipeline` composition** happens here (app target only, because `FrameExtractor`/`BallTrackerInference`/`BounceDetectorInference` are `#if !os(macOS)` iOS-only):
  ```swift
  let pipeline = CVPipeline(
      frameExtractor: FrameExtractor(),
      ballTracker: BallTrackerInference(),
      bounceDetector: BounceDetectorInference()
  )
  let vm = PostProcessingViewModel(pipeline: pipeline,
                                   videoStore: videoStore,
                                   calibrationStore: calibrationStore)
  ```
- Nav path: `MatchSummaryView → PostProcessingView(vm:matchClient:matchID:) → CVShotReviewView(vm:matchClient:matchID:)`. Wiring is build-only, so this plan is its only spec.

**Model loading (pinned):** `BallTrackerInference` / `BounceDetectorInference` load via `Bundle.main.url(forResource:withExtension:)` + `MLModel(contentsOf:)` at runtime — **NOT** Xcode auto-generated `.mlmodel` Swift classes. Auto-generated classes would break the build whenever the gitignored model file is absent, fighting the "model-absent is fine" posture. AC25 verifies `xcodebuild build` with the files **present** in `Resources/ML/`; the manual copy per `cv/README.md` is a **precondition** of AC25, not part of the build step itself.

### 3.5 Backend (Go)
**N/A** — zero backend surface change (spec §3.2, §6, §8). `source: "cv"` reuses `POST /matches/{id}/shots` and the existing `record.source` column. No route, handler, or migration.

## 4. API Contract (consumed as delivered — no new endpoint)

No new endpoint, no change to any existing one. The pipeline reuses exactly one route, delivered and verified on `main`:

| Method & path | Request body | Success body |
|---|---|---|
| `POST /matches/{id}/shots` | `{"shots":[{"zone":"…","source":"cv"},…]}` | `{"count":N}` |

The only difference from the manual flow is `source: "cv"` in each `ShotInput`. Auth (`Authorization: Bearer <token>`), error shape (`{"error":"…"}`), and status mapping are inherited unchanged from `MatchClient` (confirmed: `addShots` uses the shared `RequestExecutor`). The backend is the authority for the accepted zone set and `source` value; it stores what the client sends.

## 5. Coordinate chain (pinned — spec §4, no coder discretion)

This is the crown-jewel section. Pinned exactly so a **transpose bug cannot slip through** — a transposed application produces shape-valid output and passes any shape-only test silently.

### 5.1 Ball-pixel space — landscape `1280×720` (OQ-1 RESOLVED, human-confirmed)

The ball point from the tracker is a pixel in **1280-wide × 720-tall landscape** space (`W = 1280`, `H = 720`) — the Phase-0 TrackNet output after `×2` post-processing on the `(1,9,360,640)` (H=360, W=640) tensor (`640·2=1280`, `360·2=720`, uniform `×2` only under landscape). `fx = px/1280`, `fy = py/720` (A-1). Do not re-derive; do not adopt portrait.

### 5.2 The chain (implement verbatim — array formula, NOT simd)

Given a ball pixel `(px, py)` in `1280×720` landscape and the persisted `calibration.homographyMatrix` (9 elements, **ROW-MAJOR**, `m = [m0,m1,m2, m3,m4,m5, m6,m7,m8]`, mapping image-fraction → court-normalized):

```
Step 1 — pixel → image-fraction:
  fx = px / 1280
  fy = py / 720

Step 2 — apply the ROW-MAJOR homography (m[3r+c] addressing):
  x' = m0·fx + m1·fy + m2
  y' = m3·fx + m4·fy + m5
  w  = m6·fx + m7·fy + m8
  courtX = x' / w
  courtY = y' / w

Step 3 — court point → zone (reuse the classifier, do not reinvent):
  zone = ZoneClassifier.classify(point: CGPoint(x: courtX, y: courtY),
                                 in: CGRect(x: 0, y: 0, width: 1, height: 1))

Step 4 — package: CVShotResult(frameIndex:, zone:, normalizedCourtX: Float(courtX),
           normalizedCourtY: Float(courtY), ballPixelX: Float(px), ballPixelY: Float(py))
```

> **PIN (load-bearing — the Phase-3 transpose trap).** The application MUST be the **literal scalar formula over the row-major `[Float]` array** with `m[3r+c]` addressing, exactly as above. **Do NOT reconstruct a `simd_float3x3` from the array, and do NOT reuse `HomographyService`'s `H * columnVector` forward map.** Re-indexing the persisted array back into simd columns is precisely where the transpose re-enters (the array is the row-major flatten `out[3r+c] = H[c][r]` — confirmed in `Calibration/CalibrationStore.swift`). The equivalence `m[3r+c] == H[c][r]` is stated only as a reference; the array formula is the implementation. Applying the **transpose** (column-major, `x' = m0·fx + m3·fy + m6`) is a defect that AC15's asymmetric fixture catches.

### 5.3 Orientation invariant (must hold or zones invert — A-2, A-3)

The ball-pixel frame, the calibration `imagePoints` frame, and the recorded video frame **are the same** `1280×720` landscape frame (all from one `.mov`). The Phase-2 corner order `[TL,TR,BL,BR] → [(0,0),(1,0),(0,1),(1,1)]` fixes court-y to increase from the top image row (net side) to the bottom (baseline), which is the `ZoneClassifier` row order (row 0 = `front_court_*`, net at minY — confirmed in source). A mismatch inverts every zone while shape-only tests stay green — hence surfaced, not assumed.

### 5.4 Transpose guard fixture (AC9/AC15 — test-writer guidance)

The six-zone tests use an **asymmetric** `CourtCalibration` (non-square image quad, so `H != Hᵀ`). An identity/symmetric matrix satisfies `transpose(H)==H` and would let a transposed application pass — so the fixture MUST be asymmetric (A-7). AC15 is a **dedicated distinct test** (a 7th fixture assertion, its own case — not folded into the six zone cases): its ball pixel MUST be chosen so that applying the homography **column-major (transposed)** classifies it into a *different* zone than the correct **row-major** application. The test asserts the row-major (correct) zone; a transposed implementation fails.

Build the fixture calibration via `HomographyService.compute` over an asymmetric image quad + the unit square, flattened through the shared `CourtCalibration(homography:)` init — so the fixture's `homographyMatrix` is a genuine row-major array, not hand-typed.

> **PIN — the fixture quad is in `[0,1]` fraction space, NOT pixels.** Production persists an `H` that maps **image-fraction** → court (`tapCorner` converts px→fraction *before* `HomographyService.compute` — confirmed in `CameraSessionViewModel.tapCorner`), and the pipeline feeds it fractions (`fx=px/1280`). So the fixture image quad MUST be asymmetric fraction-space corners, e.g. `[(0.1,0.1),(0.9,0.15),(0.05,0.9),(0.95,0.85)]` in `[TL,TR,BL,BR]`. **Do NOT copy the Phase-2 pixel-valued quad** (`(100,50),(1920,50),…`) — that builds an `H` mapping pixel→court; feeding it fractions collapses every court point near the origin and the six zones cannot be spread. This is self-revealing but costs a debug cycle if missed.

## 6. Data Model Changes

**None.** No database, schema, or migration change (spec §8). `source = 'cv'` is a **value**, not a schema change — the `record.source` column (Phase 1) accepts what the client sends. The only on-device data:
- `Documents/videos/{matchId}.mov` — read via `LocalVideoStore` (Phase 2).
- `Documents/calibrations/{matchId}.json` — read via `CalibrationStore` (Phase 2).
No CV artifact is persisted server-side.

### Gitignore additions (§8)
```
cv/models/
ios/TennisShotTracker/TennisShotTracker/Resources/ML/
```
Both hold large binary model files produced by `convert_models.py` and copied manually per `cv/README.md`; neither is committed.

## 7. Sequence Diagram (text)

**Analyse → review → submit (the user-triggered path):**
1. On `MatchSummaryView`, the "Analyse Video" action is shown only when `LocalVideoStore.exists(for: matchID)` **and** `CalibrationStore.exists(for: matchID)` (AC26). Tap → construct the concrete `CVPipeline` (composition root, §3.4) + `PostProcessingViewModel`, navigate to `PostProcessingView`.
2. `PostProcessingView` on appear → `await vm.startProcessing(matchId:matchClient:)`.
3. VM resolves video URL + calibration; if either missing → `.failed` (AC23). Else `.processing(0.0)`.
4. `CVPipeline.process`: extract frames (stride 1, OQ-3) → track balls → detect bounces → for each bounce frame with a non-nil ball, apply the §5.2 chain → `ZoneClassifier` zone → `CVShotResult`. Progress drives `.processing(progress)` (AC13).
5. Success → `.done(shots)`; `PostProcessingView` routes to `CVShotReviewView` (AC17).
6. `CVShotReviewView` lists shots with zone badges. **Submit N** → `vm.submit` → `addShots(matchID:, shots: map { ShotInput(zone:, source:"cv") })` (AC19/AC20). **Discard** → `vm.dismiss()` → `.idle` (AC22).
7. Submit transport failure → `.failed`, shots retained for retry (AC21).

**Coordinate chain (the transpose-critical path):**
1. `CVPipeline` reads `calibration.homographyMatrix` — the row-major `[Float]`.
2. For a bounce ball pixel `(px,py)`: `fx=px/1280, fy=py/720`; apply the **row-major array formula** (`m[3r+c]`), normalize by `w` → `(courtX, courtY)`.
3. `ZoneClassifier.classify((courtX,courtY), CGRect(0,0,1,1))` → one of six strings.
4. AC9/AC15 asymmetric fixture asserts row-major-correct zones; a transposed application misclassifies at least one pixel and fails.

## 8. AC → Design coverage matrix

| AC | Satisfied by | Where |
|---|---|---|
| AC1 (requirements.txt pins) | `cv/requirements.txt` | Python |
| AC2 (TrackNet → BallTracker.mlpackage) | `convert_models.py` | Python |
| AC3 (CatBoost → BounceDetector.mlmodel) | `convert_models.py` | Python |
| AC4 (prints I/O specs — OQ-2 hook) | `convert_models.py` | Python |
| AC5 (README setup + manual copy) | `cv/README.md` | Python |
| AC6 (Mock 0 results → empty) | `MockCVPipeline` | CV/ |
| AC7 (Mock N results → N in order) | `MockCVPipeline` | CV/ |
| AC8 (Mock error → throws) | `MockCVPipeline` | CV/ |
| AC9 (six-zone asymmetric fixture) | `CVPipeline` §5.2 chain + fixture | CV/ |
| AC10 (ballPixel/normalizedCourt fields) | `CVPipeline` Step 4 | CV/ |
| AC11 (nil-ball bounce skipped) | `CVPipeline` step 5 | CV/ |
| AC12 (empty bounce set → []) | `CVPipeline` | CV/ |
| AC13 (monotonic progress ≥1 call) | `CVPipeline` progress | CV/ |
| AC14 (one result per non-nil-ball bounce, in order) | `CVPipeline` | CV/ |
| AC15 (transpose guard — column-major fails) | asymmetric fixture pixel | CV/ (§5.4) |
| AC16 (initial .idle) | `PostProcessingViewModel` | CV/ |
| AC17 (.idle→.processing→.done N) | `startProcessing` | CV/ |
| AC18 (throw → .failed) | `startProcessing` catch | CV/ |
| AC19 (submit: N shots, all source "cv", zones match) | `submit` | CV/ |
| AC20 (every zone one of six) | `submit` (via ZoneClassifier) | CV/ |
| AC21 (submit failure → .failed, shots retained) | `submit` catch + retained store | CV/ |
| AC22 (dismiss → .idle) | `dismiss` | CV/ |
| AC23 (missing video OR calibration → .failed, two cases) | `startProcessing` guard | CV/ |
| AC24 (hermetic, 144+, no CoreML file) | `#if !os(macOS)` + protocol-only deps | §2 / all CV/ |
| AC25 (xcodebuild build w/ models present) | app target + composition root | app target (§3.4) |
| AC26 (Analyse Video gated on video+calibration) | `MatchSummaryView` | app target |
| AC27 (progress bar + cancel; review list + Submit N/Discard) | `PostProcessingView` / `CVShotReviewView` | app target |
| AC28 (no CV/zone/coord/net logic in app target) | thin views | app target |
| AC29 (no new Swift dependency) | Package.swift untouched | Package.swift / app target |

Every AC1–AC29 maps to at least one task (§ tasks doc). No orphans.

## 9. Risks & Mitigations

- **Silent transpose bug (the central Phase-3 risk).** The persisted homography is row-major `[Float]`; a coder reaching for the familiar `simd_float3x3` + `H * columnVector` path (or re-indexing the array into simd columns) re-introduces the transpose, which passes any shape-only test. **Mitigations, baked into tasks:** (a) §5.2 pins the **literal row-major array formula** and **forbids** simd reconstruction / `HomographyService` reuse; (b) the AC9/AC15 fixture is **asymmetric** (`H != Hᵀ`) with at least one pixel that lands in a *different* zone under column-major application, so a transposed implementation fails `swift test`; (c) the fixture matrix is built via `HomographyService.compute` + the shared `CourtCalibration(homography:)` flatten, so it is a genuine row-major array, not hand-typed (§5.4).
- **OQ-2 — bounce 12-column feature order (load-bearing, UNRESOLVED).** `BounceDetectorInference` builds a 12-column feature vector, but the exact order is **not derivable from any source on this branch** and the file is `#if`-guarded with **no `swift test`** — a wrong order yields garbage with all shape-tests green. **Mitigation:** the coder MUST reproduce the **Phase-0 CatBoost training feature order byte-for-byte** (the training/inference code that produced `bounce.cbm` is the authority), confirm it against `convert_models.py`'s printed input spec (AC4), and **record the recovered order in `cv/README.md`**. It MUST NOT be guessed. Flagged at the task level (Task 9) and surfaced for Gate 2, not silently assumed.
- **Hermetic gate broken by the wrong `#if` guard.** `#if canImport(CoreML)` would compile the inference types into the macOS test build (CoreML canImports on macOS) and break AC24. **Mitigation:** the guard is `#if !os(macOS)` (the shipped `CameraService` precedent); protocols + mocks are unguarded, concrete inference types are guarded (§2).
- **Model-absent build break.** Xcode auto-generated `.mlmodel` Swift classes would fail the build when the gitignored model is absent. **Mitigation:** load at runtime via `MLModel(contentsOf:)` + `Bundle.url(forResource:)`; no codegen dependency (§3.4). AC25 tolerates model-present build; model-absent is fine for `swift test`.
- **Coordinate frame orientation inversion (A-2/A-3).** If the ball-pixel, calibration, and video frames disagreed in orientation, every zone would invert silently. **Mitigation:** §5.3 pins the single-shared-frame invariant and surfaces it for review; the AC9 fixture asserts concrete zones per pixel.
- **`xcodebuild build` env-blocked.** Known, carried from Phase 1/2. The real gate is `swift test`. Fall back to the `swiftc -typecheck` compensator and record which path was used for Gate 2 — a build-env failure is NOT a code defect (§10).
- **Phase-0 model efficacy out of scope (A-10).** This phase wires the pipeline assuming the converted models detect balls/bounces; `SPIKE_RESULT.md` notes bounce detection is unconfirmed on real footage. A ~0-bounce result on real footage is a Phase-0/model finding, not a defect in this wiring.
- **`@Observable` toolchain.** Phase 1/2 proved `@Observable` builds on this host (`RecordSessionViewModel`, `CameraSessionViewModel`). Same pattern for `PostProcessingViewModel`.

## 10. Verification Gates (spec §10)

- `cd ios/TennisCore && swift test` passes — **the real gate**. **119 existing + 25 new = 144+ tests, 0 failures**, with **no CoreML model file present** (hermetic, §2 / AC24). Budget below.
- Zone strings emitted match the six-value backend enum byte-for-byte (`front_court_left/right`, `baseline_left/right`, `out_left/right`; no `out_behind`) — AC20 (produced solely by `ZoneClassifier`).
- `xcodebuild build` of the `TennisShotTracker` app target succeeds (compile-only; no simulator), with the `Resources/ML/` model files present — AC25. **If the iOS destination is unresolvable, fall back to `swiftc -typecheck` over the app-target sources against the iOS-built `TennisCore` module** (Phase-1/2 compensator); record which path was used for Gate 2. A build-env failure is NOT a code defect and must not block the green TennisCore work.
- `python cv/convert_models.py` verified by a **manual** run producing `BallTracker.mlpackage` + `BounceDetector.mlmodel` and printing I/O specs — AC2–AC4 (not part of `pytest`/CI).
- Branch `feat/phase3-cv` (off `origin/main`/`bdec000`); PR targets `main`, labeled `ai-generated`, never merged autonomously — Gate 2.

**Test-count budget (clears the 144 gate):**

| Tested component | New tests |
|---|---|
| `MockCVPipeline` / `CVProcessing` contract (AC6–AC8) | 3 |
| `CVPipeline` coordinate chain: six-zone asymmetric fixture (AC9, one case per zone) | 6 |
| `CVPipeline`: field passthrough (AC10), nil-ball skip (AC11), empty bounce (AC12), pipeline progress (AC13), order (AC14) | 5 |
| `CVPipeline`: transpose guard (AC15 — dedicated distinct 7th fixture case, NOT folded into the six) | 1 |
| `PostProcessingViewModel` (AC16–AC22: idle, processing→done, throw→failed, submit source/zones, submit-fail retain, dismiss = 7 tests) | 7 |
| `PostProcessingViewModel`: VM-side progress plumbing (the pipeline's `progress` callback drives `.processing(progress)` — the AC27 progress bar depends on this; AC13 alone only covers pipeline-level progress) | 1 |
| `PostProcessingViewModel` guard (AC23: missing video, missing calibration — two cases) | 2 |
| **Total new** | **25** |
| Existing (on `main`) | 119 |
| **Grand total** | **144** ✅ (= 144) |

> AC24 (hermetic) is proven by the whole suite compiling + passing with the `#if !os(macOS)` types excluded and no model file present — not a discrete test. **AC15 is a dedicated distinct test (a 7th fixture case with its own transpose-catching pixel), NOT folded into the six AC9 zone cases** — this is what makes the budget deterministically 25 (6 zone + AC10/11/12/13/14 = 5 + AC15 = 1 in `CVPipeline`; 7 + VM-progress + AC23×2 = 10 in the VM). App-target ACs (AC25–AC29) are build-only + inspection.

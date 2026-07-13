# Plan: iOS App — Camera Recording & Court Calibration (Phase 2)

**Spec:** `docs/specs/spec-phase2-camera-2026-07-13.md` (Gate-1 approved)
**Date:** 2026-07-13
**Author:** architect (AI)
**Branch:** `feat/phase2-camera` off `main` (spec §10). All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Gate-1 OQ defaults LOCKED (spec §11 — the coder does NOT re-open them):**
> - **OQ-1 (SVD solver):** Accelerate `dgesdd_` in **double precision**, cast to `Float` at the return boundary. No third-party dep. Hand-rolled Jacobi is an acceptable fallback only if LAPACK C-interop proves unworkable — the contract is FR-H1's signature + behavior, not the solver.
> - **OQ-2 (permission denied):** a terminal `.permissionDenied` case, distinct from `.permissionPending`. `startPreview` never reaches `.previewing` on denial (AC15).
> - **OQ-3 (tapCorner before preview):** **no-op** — a `tapCorner` while not in `.previewing`/`.tappingCorners` leaves state and accumulated points unchanged (AC22).
> - **OQ-4 (fraction origin):** origin top-left, `+y` down, points `[TL,TR,BL,BR]`, court = unit square (spec §4). No action.
> - **OQ-5 (Redo):** "Redo" clears **all four** taps and restarts from Top-Left (build-only view detail).
> - **OQ-6 (recording start):** auto-start — `startRecording` fires on entry to the recording session, right after calibration.
> - **OQ-7 (lifecycle):** **overwrite** — recording a match that already has a `.mov`/calibration overwrites both (fixed per-match path). Orphan cleanup deferred.

---

## 0. Non-goals (carried forward from spec §2.1 / §6)

Explicitly **not** built this slice:
- **No backend surface change** — no routes, no handlers, no migrations, no Go code. End Match reuses `POST /matches/{id}/end` exactly as Phase 1 delivered.
- **No CV / CoreML** — the homography is computed and **persisted as prep for Phase 3**; nothing this slice consumes it beyond writing it (A-1). No `cv` shots; `match.source` stays `'manual'`.
- **No upload of video or calibration** — both are on-device only (`Documents/videos/{matchId}.mov`, `Documents/calibrations/{matchId}.json`). `video_ref` left to its backend default (Phase-1 A-5).
- **No change to the Phase-1 zone tap grid, `ZoneClassifier`, or `RecordSessionViewModel`** — shot recording and End Match are unchanged; camera is purely additive.
- **No match-delete UI, no re-calibration flow, no orphan cleanup** — deferred (OQ-7).
- **No iOS simulator / UI tests / iOS CI job** — no simulator runtime on the build machine (§2.3). AVFoundation files and views are compile-only.
- **No new third-party dependency** (AC28). Accelerate, AVFoundation, simd, CoreGraphics, Observation are system frameworks, not SPM deps.

## 1. Architecture Overview

This slice adds on-device camera recording and 4-corner court calibration on top of the Phase-1 TennisCore foundation, with **zero backend change** and **all math + state-machine logic in TennisCore** so it is provable by `swift test` (the real gate; `xcodebuild` is env-blocked, §2.3 / §8). The single hard component is `HomographyService` — a pure-math DLT/SVD solver mapping image points → the normalized unit-square court. It carries a **silent transpose risk** because three coordinate-storage conventions collide: `simd_float3x3` is column-major in memory, LAPACK `dgesdd_` is column-major, but the persisted `CourtCalibration.homographyMatrix` is pinned **row-major**. A transpose slip compiles and passes any diagonal/identity/scaled-rect test — so the plan pins the row-major indexing verbatim (§2.1.1), routes the `simd → [Float]` conversion through **one shared helper** so the VM and the store-test cannot diverge, and requires the HomographyService tests to include an **asymmetric offset-rect case, a perspective trapezoid case, AND a forward-mapping round-trip** (apply `H` to the four image points, normalize by homogeneous `w`, assert they land on the court corners within epsilon) — not only element-wise comparison against a hand-typed matrix (§6, Risks).

Around that sits a `CameraCapturing` protocol (the capture **seam**), a `MockCameraService` (compiled on all platforms, in `Sources/`), a concrete AVFoundation `CameraService` (`#if !os(macOS)`, build-only), and two file-backed stores (`CalibrationStore`, `LocalVideoStore`). A single new `@Observable` `CameraSessionViewModel` owns the camera/calibration state machine, depends on all of the above, and is `swift test`-able via `MockCameraService`. The SwiftUI views (`CameraSetupView`, `CornerTapView`, camera additions to `RecordSessionView`) are thin readers, build-only. `RecordSessionView` gains an **additive optional `CameraSessionViewModel?` param defaulting to `nil`**, so every Phase-1 test and call site stays green with zero test edits. `MatchListView` gains two `Route` cases (`.cameraSetup`, `.cornerTap`) wired into its existing `navigationDestination` switch; the active-match path now routes `.cameraSetup → .cornerTap → .session`, the ended-match `.summary` path is unchanged.

### Environment reality (stated, not fixed)

There is **no iOS simulator runtime on the build machine**. `swift test` in `ios/TennisCore` is the **real gate** (target **106+ tests, 0 failures**; **86 exist today** → **20+ new**). App-target and AVFoundation files are **build-only** (`swiftc -typecheck` / `xcodebuild build`), which may itself be blocked by the missing iOS platform — that is a **known deferred Gate-2 item, not a task failure** (§8, Task 11). A build-env failure never blocks the green TennisCore work.

## 2. Component Design

### 2.1 iOS (Swift) — `ios/TennisCore` package (tested + one build-only file)

**New files:**
```
ios/TennisCore/Sources/TennisCore/
├── Calibration/
│   ├── HomographyService.swift        # pure-math DLT/SVD (FR-H1) — swift test
│   ├── CalibrationStore.swift          # CourtCalibration persist/load (FR-H2) — swift test
│   └── CameraSessionViewModel.swift    # @Observable state machine (FR-VM1) — swift test (MockCameraService)
└── Camera/
    ├── CameraCapturing.swift           # capture seam protocol (FR-C1) — compiles on macOS
    ├── MockCameraService.swift         # in-memory stub (FR-C3) — all platforms, in Sources/ (not Tests/)
    ├── LocalVideoStore.swift           # Documents/videos/{matchId}.mov (FR-C4) — swift test
    └── CameraService.swift             # AVFoundation concrete (FR-C2) — #if !os(macOS), BUILD-ONLY
```

**No modified TennisCore files.** `Package.swift` is untouched (AC28). Accelerate / simd / CoreGraphics / AVFoundation are system frameworks; no `dependencies:` change.

**Test-vs-typecheck boundary (spec §5, pinned):**

| File | Verified by |
|---|---|
| `Calibration/HomographyService.swift` | `swift test` |
| `Calibration/CalibrationStore.swift` | `swift test` |
| `Calibration/CameraSessionViewModel.swift` | `swift test` (with `MockCameraService`) |
| `Camera/CameraCapturing.swift` | `swift test` (compiles on macOS) |
| `Camera/MockCameraService.swift` | `swift test` |
| `Camera/LocalVideoStore.swift` | `swift test` |
| `Camera/CameraService.swift` | build-only (`#if !os(macOS)`, NOT compiled on macOS) |
| `Views/CameraSetupView.swift`, `CornerTapView.swift`, `RecordSessionView` additions, `MatchListView` routing | build-only |

#### 2.1.1 `Calibration/HomographyService.swift` (FR-H1 — the load-bearing pure-math component)

Signature (pinned):
```swift
import Foundation
import CoreGraphics   // CGPoint
import simd
import Accelerate     // dgesdd_ (OQ-1)
// MUST NOT import AVFoundation, UIKit, CoreImage, Vision (§2.2, AC29)

public enum HomographyService {
    /// Solves the 4-point DLT homography mapping imagePoints → courtPoints.
    /// Returns nil on: count != 4 (either list), mismatched counts, degenerate/collinear
    /// configuration, or |h22| < 1e-9 after solving.
    public static func compute(imagePoints: [CGPoint], courtPoints: [CGPoint]) -> simd_float3x3?
}
```

**Algorithm (pinned, no coder discretion):**
1. **Guards (AC4/AC5/AC6):** `guard imagePoints.count == 4, courtPoints.count == 4 else { return nil }`. (Mismatched counts fail this same guard.)
2. **Build the 8×9 DLT matrix `A`** in **double precision**. For each corresponding pair `(x,y) → (u,v)` add the two standard rows:
   - `[-x, -y, -1,  0,  0,  0,  u*x,  u*y,  u]`
   - `[ 0,  0,  0, -x, -y, -1,  v*x,  v*y,  v]`
3. **Solve for the null vector `h` (9 elements)** via SVD of `A` (OQ-1: Accelerate `dgesdd_`, double precision). `h` is the right-singular vector for the smallest singular value — i.e. the last row of `Vᵀ` (equivalently last column of `V`). LAPACK is column-major: transpose `A` into column-major storage before the call, and read the null vector from `VT`'s last row per LAPACK's `VT` layout. **This is transpose point #1 — see the Risks section and the round-trip requirement below.**
4. **Degenerate detection (AC4 — pinned, testable criterion, no coder discretion):** `dgesdd_` returns the singular values `S` in **descending** order. A well-posed 4-point set has rank(A)=8 → σ0..σ7 > 0 and σ8 ≈ 0 (the 1-D null space). A collinear/degenerate set drops rank, so **σ7 also collapses toward 0**. Criterion: **if `S[7] / S[0] < 1e-6` (second-smallest singular value relative to the largest), return `nil`.** Also return `nil` if the `h22` normalization guard (step 5) trips. **DO NOT use a determinant or element-magnitude guard** — it is not scale-robust: the AC2 offset-rect is a *valid* homography whose determinant is ≈ `(1/1820)·(1/1030) ≈ 5.3e-7`, so an `abs(det) < 1e-6 → nil` check would wrongly reject it. The singular-ratio criterion is scale-invariant and does not have this failure.
5. **Scale-normalize (FR-H1, pinned, load-bearing):** a homography is defined only up to a scalar. Divide all 9 elements of `h` by `h[8]` (the `h22` bottom-right entry) so `h22 == 1.0`. If `|h[8]| < 1e-9` before normalization, return `nil` (a valid court homography never has a zero bottom-right entry).
6. **The normalized `h` IS the row-major 9-vector** `[h00,h01,h02, h10,h11,h12, h20,h21,h22]`. This is the single source of truth for both derived views (matrix and stored array) — see §2.1.2.
7. **Build the `simd_float3x3` from `h`** by casting each element to `Float`. Because `simd_float3x3(columns:)` takes **columns**, group as:
   ```swift
   simd_float3x3(columns: (
       SIMD3<Float>(h0, h3, h6),   // column 0
       SIMD3<Float>(h1, h4, h7),   // column 1
       SIMD3<Float>(h2, h5, h8)    // column 2
   ))
   ```
   With this construction, element `(row r, col c)` is `M[c][r]` (simd is column-major), and `M[c][r]` equals `h[3*r + c]` — the row-major invariant the whole slice depends on.

**Forward-mapping convention (pinned — the same expression Phase 3 will consume):**
```swift
let p = H * simd_float3(Float(x), Float(y), 1)   // H times a COLUMN vector
let court = (p.x / p.z, p.y / p.z)                // normalize by homogeneous w
```
The HomographyService round-trip tests (AC2 offset-rect center→(0.5,0.5), AC3 trapezoid) **MUST apply `H` this way — `H * columnVector`, not `vector * H`**. Applying it as a row-vector (`v * M`) launders the transpose and lets a wrong matrix pass. This is called out again in the Task 1 test guidance.

#### 2.1.2 `Calibration/CalibrationStore.swift` (FR-H2)

```swift
public struct CGPointCodable: Codable, Equatable {
    public var x: Double
    public var y: Double
}

public struct CourtCalibration: Codable, Equatable {
    public let matchId: String
    public let imagePoints: [CGPointCodable]   // [TL,TR,BL,BR], image-fraction coords
    public let courtPoints: [CGPointCodable]   // always [(0,0),(1,0),(0,1),(1,1)]
    public let homographyMatrix: [Float]        // 9 elements, ROW-MAJOR

    /// THE SINGLE conversion seam (transpose point #2). Both the VM (AC21) and the
    /// AC10a store test construct CourtCalibration through this init, so the
    /// simd → [Float] flatten cannot diverge between production and test.
    public init(matchId: String,
                imagePoints: [CGPointCodable],
                courtPoints: [CGPointCodable],
                homography H: simd_float3x3) {
        self.matchId = matchId
        self.imagePoints = imagePoints
        self.courtPoints = courtPoints
        // Row-major flatten: element (row r, col c) of a column-major simd_float3x3
        // is H[c][r].  out[3*r + c] = H[c][r].
        var out = [Float]()
        for r in 0..<3 { for c in 0..<3 { out.append(H[c][r]) } }
        self.homographyMatrix = out   // [h00,h01,h02, h10,h11,h12, h20,h21,h22]
    }

    // A memberwise/decodable init is also needed for Codable round-trip (AC7/AC10).
}

public struct CalibrationStore {
    public init(baseDirectory: URL? = nil)   // A-4: injectable base dir; default = Documents/
    public func save(_ calibration: CourtCalibration) throws
    public func load(for matchId: String) -> CourtCalibration?   // nil, not throw, on unknown (AC8)
    public func exists(for matchId: String) -> Bool
    public func delete(for matchId: String) throws               // no-op if absent (AC9)
}
```

- Path: `<baseDirectory ?? Documents>/calibrations/{matchId}.json`. The `calibrations/` directory is created on first `save`.
- JSON shape (AC10): each point encodes as `{"x":<double>,"y":<double>}`; `homographyMatrix` is a flat 9-element JSON number array (row-major).
- `load` returns `nil` (never throws, never crashes) for an unknown/absent `matchId` (AC8).

> **The `homography:` init is the transpose seam.** AC10a (row-major element order for a **non-diagonal** matrix) is the only guard that distinguishes row-major from simd's native column-major layout. It is load-bearing precisely because the AC7/AC10 Codable round-trip cannot see a transpose (a symmetric round-trip through the same flatten passes either way). AC10a therefore uses the AC2 offset-rect or AC3 trapezoid homography — where translation/perspective entries move position under transpose — and asserts index `0..8 == [h00,h01,h02, h10,h11,h12, h20,h21,h22]` with `h22 == 1.0`.

#### 2.1.3 `Camera/LocalVideoStore.swift` (FR-C4)

```swift
public struct LocalVideoStore {
    public init(baseDirectory: URL? = nil)   // A-4: injectable base dir; default = Documents/
    public func videoURL(for matchId: String) -> URL          // <base>/videos/{matchId}.mov (AC11)
    public func exists(for matchId: String) -> Bool
    public func delete(for matchId: String) throws            // no-op if absent (AC12)
}
```

- Manages `<baseDirectory ?? Documents>/videos/{matchId}.mov`; creates the `videos/` directory as needed (before the camera writes to `videoURL`).
- `videoURL(for:)` ends in `videos/{matchId}.mov` (AC11).

> **Test-isolation decision (A-4 — architect-pinned, no coder discretion).** There is **no existing FileManager-based store** in TennisCore to mirror (KeychainTokenStore is Keychain, not files), so A-4's "mirror the existing store tests" has no precedent to point at. **Decision: both file stores take an optional `baseDirectory: URL? = nil` init param, defaulting to the app Documents directory.** Tests inject a unique per-test temporary directory (`FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`) and remove it in `tearDown`. This is hermetic, parallel-safe, and avoids writing to the real `~/Documents` under `swift test` (where Documents resolves to a real on-disk location). A-4 pre-blesses adding this seam. The spec's `static func videoURL(for:)` sketch becomes an **instance** method as a consequence — the store is a value type constructed with the base dir.

#### 2.1.4 `Camera/CameraCapturing.swift` (FR-C1) + `Camera/MockCameraService.swift` (FR-C3) + `Camera/CameraService.swift` (FR-C2)

```swift
import AVFoundation   // CameraCapturing DOES import AVFoundation — the §2.2 import ban is HomographyService-ONLY.

public protocol CameraCapturing {
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    func requestPermission() async -> Bool
    func startPreview() throws
    func startRecording(to url: URL) throws
    func stopRecording() async throws
    func stopPreview()
}
```

- **`AVCaptureVideoPreviewLayer` is available on macOS (A-2)**, so the protocol, `MockCameraService`, and `CameraSessionViewModel` compile under `swift test`. **A-2 is asserted-but-unverified** — "verify at first compile." Task 4 (CameraCapturing + Mock) exists specifically to **prove A-2 before the VM is built on top of it**. **A-2 fallback (contingency, not a mid-build surprise):** if `AVCaptureVideoPreviewLayer` will not build on macOS, abstract `previewLayer` behind a platform typealias or move only that member behind `#if !os(macOS)`, keeping the rest of the seam macOS-testable — flagged because it changes the tested surface.
- **`MockCameraService` lives in `Sources/TennisCore/Camera/`, NOT in `Tests/`** (spec §5 pins the path). It mirrors `InMemoryTokenStore` (a shipped stub used in tests + previews), **not** `StubTransport` (a test-only helper). `requestPermission()` returns a configurable stubbed `Bool`; `startRecording(to:)` writes an empty file at the URL; `stopRecording()` resolves immediately; `previewLayer` returns a plain `AVCaptureVideoPreviewLayer()` valid to reference on macOS.
- **`CameraService.swift` is entirely wrapped in `#if !os(macOS)`** and is NOT compiled into the macOS `swift test` build (AC25). AVFoundation capture-session setup, records to the given URL as `.mov`. Build-only verified.

#### 2.1.5 `Calibration/CameraSessionViewModel.swift` (FR-VM1, D-3 — the state machine)

```swift
import Foundation
import CoreGraphics
import simd
import Observation

public enum CameraSessionState: Equatable {
    case permissionPending
    case permissionDenied              // OQ-2 terminal
    case previewing
    case tappingCorners(count: Int)    // count 1..3 (4th auto-advances)
    case calibrated
    case recording
    case done
}

@Observable
public final class CameraSessionViewModel {
    public private(set) var state: CameraSessionState = .permissionPending   // AC13
    public private(set) var imagePoints: [CGPoint] = []    // fraction coords, [TL,TR,BL,BR]
    public private(set) var homography: simd_float3x3?     // non-nil once calibrated

    // Dependencies injected at init (Phase-1 DI precedent — see signature note below).
    public init(camera: CameraCapturing,
                calibrationStore: CalibrationStore = CalibrationStore(),
                videoStore: LocalVideoStore = LocalVideoStore())

    public func startPreview() async               // requests permission, transitions
    public func tapCorner(at point: CGPoint, imageSize: CGSize)
    public func startRecording(matchId: String) throws
    public func stopRecording() async throws
    public func saveCalibration(for matchId: String) throws
}
```

> **Signature resolution (architect-pinned — the ACs and FR-VM1 conflict).** The ACs write `startPreview(camera:)` but FR-VM1 injects `CameraCapturing` at init. The Phase-1 DI precedent (`RecordSessionViewModel(client:matchID:)`, `SessionStore(client:tokenStore:)`) is the tie-breaker: **inject `camera: CameraCapturing` at init; `startPreview()` is no-arg.** The `camera:` label in the ACs is read as the init dependency, not a per-call argument. Coder and test-writer see this one signature.

**Method behavior (pinned):**
- `startPreview()` — `await camera.requestPermission()`; on `true` → `camera.startPreview()`, state `.previewing` (AC14); on `false` → state `.permissionDenied`, never `.previewing` (AC15/OQ-2).
- `tapCorner(at:imageSize:)` — **guard (OQ-3):** only acts in `.previewing` or `.tappingCorners`; otherwise **no-op** (state and points unchanged) (AC22). Converts the pixel point to fraction coords `CGPoint(x: point.x/imageSize.width, y: point.y/imageSize.height)` (§4) and appends in tap order (AC18). After each append: 1..3 points → `.tappingCorners(count: n)` with `homography == nil` (AC16); the **4th** point auto-advances to `.calibrated` and sets `homography = HomographyService.compute(imagePoints: imagePoints, courtPoints: unitSquare)` where `unitSquare = [(0,0),(1,0),(0,1),(1,1)]` (AC17).
- `startRecording(matchId:)` — resolves `videoStore.videoURL(for: matchId)`, calls `camera.startRecording(to:)`, state `.recording` (AC19).
- `stopRecording()` — `await camera.stopRecording()`, state `.done` (AC20).
- `saveCalibration(for matchId:)` — requires `homography != nil`; builds a `CourtCalibration` **through the shared `homography:` init** (§2.1.2) with the VM's four `imagePoints` (as `CGPointCodable`), the unit-square `courtPoints`, and the computed matrix; `calibrationStore.save(...)` (AC21).

### 2.2 iOS (Swift) — `TennisShotTracker` app target (thin, build-only)

**New files:**
```
ios/TennisShotTracker/TennisShotTracker/Views/
├── CameraSetupView.swift    # live preview (UIViewRepresentable → AVCaptureVideoPreviewLayer) + guide overlay + Next (FR-V1)
└── CornerTapView.swift       # sequential 4-corner tap + dots + Redo → recording session (FR-V2)
```

**Modified files (build-only):**
- `ios/TennisShotTracker/TennisShotTracker/Views/RecordSessionView.swift` — **additive** optional param (FR-V3, D-2, AC26).
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchListView.swift` — two new `Route` cases wired into the existing switch (FR-V5, D-1, AC27).
- `ios/TennisShotTracker/TennisShotTracker/*.plist` / app-target settings — add `NSCameraUsageDescription` (A-3; build detail, not code).
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add the two new view files to the app-target Sources build phase.

**View responsibilities (all thin — no math/networking/state-machine logic in the app target):**
- **`CameraSetupView` (FR-V1):** a `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer` (from `cameraVM.camera.previewLayer` via the seam), a corner-bracket guide overlay, framing-guidance text, and a "Next" action that advances the nav path to `.cornerTap`. Driven by `CameraSessionViewModel`.
- **`CornerTapView` (FR-V2):** sequential prompts ("Tap Top-Left corner" … "Tap Bottom-Right corner"), a colored dot at each tapped point, a "Redo" button (OQ-5: clears all four, restarts from TL). Hands each tap to `cameraVM.tapCorner(at:imageSize:)` in the §4 convention. On the 4th tap, once `cameraVM.homography != nil`, calls `saveCalibration(for:)` (FR-V4 — persist before recording ends) and advances the path to `.session`.
- **`RecordSessionView` (FR-V3, additive):** see §2.3.
- **`MatchListView` routing (FR-V5):** see §2.4.

### 2.3 RecordSessionView additive change (FR-V3, D-2, AC26 — zero test edits)

Current init: `init(matchClient: MatchClient, matchID: String, path: Binding<[Route]>)`.

New init (additive, trailing optional defaulting to `nil`):
```swift
init(matchClient: MatchClient,
     matchID: String,
     path: Binding<[Route]>,
     cameraVM: CameraSessionViewModel? = nil)   // NEW, default nil
```
- When `cameraVM == nil`: behavior is **exactly Phase 1** — no camera UI, existing tests and call sites unaffected (AC26). MatchListView's current `.session` call site (`RecordSessionView(matchClient:matchID:path:)`) still compiles because the new param defaults.
- When `cameraVM != nil`: on appear, `startRecording(matchId:)` fires (OQ-6 auto-start); show an inline camera preview thumbnail and a `● REC` badge while `state == .recording`; the zone tap grid + shot recording via `RecordSessionViewModel` are **unchanged**.
- **End Match ordering (FR-V3):** when a `cameraVM` is present, End Match calls `cameraVM.stopRecording()` **before** the existing `RecordSessionViewModel.endMatch()` posts to the backend. When absent, End Match is exactly Phase 1.

### 2.4 MatchListView routing (FR-V5, D-1, AC27 — how the new Route cases wire in)

The existing `Route` enum is `Hashable`/String-payload and **cannot carry a `CameraSessionViewModel`** (which holds live tap/homography state). One VM instance must therefore be **created once and shared across all three destinations** of the calibration→record flow.

**Pinned wiring (build-only — this is the only place it gets specified):**
- Extend `Route`:
  ```swift
  enum Route: Hashable {
      case cameraSetup(String)   // NEW — matchId
      case cornerTap(String)     // NEW — matchId
      case session(String)
      case summary(String)
  }
  ```
- `MatchListView` gains `@State private var cameraVM: CameraSessionViewModel?`. On entry to the calibration flow (active-match tap or newly-created match), it constructs **one** `CameraSessionViewModel(camera: CameraService(), ...)` and stores it, then appends `.cameraSetup(match.id)`.
- The `navigationDestination(for: Route.self)` switch injects **that same `cameraVM` instance** into all three destinations:
  ```swift
  case .cameraSetup(let id): CameraSetupView(cameraVM: cameraVM!, matchID: id, path: $path)
  case .cornerTap(let id):   CornerTapView(cameraVM: cameraVM!, matchID: id, path: $path)
  case .session(let id):     RecordSessionView(matchClient: matchClient, matchID: id, path: $path, cameraVM: cameraVM)
  case .summary(let id):     MatchSummaryView(matchClient: matchClient, matchID: id)   // UNCHANGED
  ```
- **Routing change:** an **active**-match tap now routes `.cameraSetup → .cornerTap → .session` (was direct `.session`). The **created**-match path (`onChange(of: viewModel.createdMatch?.id)`) routes the same way (append `.cameraSetup(id)` instead of `.session(id)`). The **ended**-match path (`.summary`) is **unchanged** (D-1, AC27).

### 2.5 CV Pipeline (Python)
**N/A** — explicit non-goal (§2.1 / §6). The homography is computed and persisted as prep for Phase 3; no CV/CoreML runs this slice.

### 2.6 Backend (Go)
**N/A** — zero backend surface change (§2.1). End Match reuses `POST /matches/{id}/end` exactly as Phase 1 delivered.

## 3. Data Model Changes

**None.** No database, schema, or migration change — this is a client-only, on-device slice (§2.1 / spec §7). `match.source` stays `'manual'`; `video_ref` left to its backend default (Phase-1 A-5). The only new persisted data is on-device and outside the database:
- `Documents/videos/{matchId}.mov` — recorded session video (via `LocalVideoStore`; overwrite per OQ-7).
- `Documents/calibrations/{matchId}.json` — one `CourtCalibration` per match (via `CalibrationStore`; overwrite per OQ-7).

## 4. API Contract

**None new** (spec §8). No endpoint is added, changed, or newly consumed. The only backend interaction is the existing `POST /matches/{id}/end` (Phase-1 route 4), called unchanged by `RecordSessionViewModel.endMatch()` **after** the camera VM's `stopRecording()`. No request carries video or calibration data.

## 5. Coordinate & Homography Convention (pinned — spec §4, no coder discretion)

- **Image-point order is always `[TL, TR, BL, BR]`** — in `tapCorner` collection and in persisted `CourtCalibration.imagePoints`.
- **Image points stored in image-fraction coords** — each component `[0,1]`, `x = px/imageWidth`, `y = py/imageHeight`, **origin top-left** (`+x` right, `+y` down). `CameraSessionViewModel.tapCorner(at:imageSize:)` does the conversion.
- **Court points always the unit square in `[TL,TR,BL,BR]`:** `TL=(0,0)`, `TR=(1,0)`, `BL=(0,1)`, `BR=(1,1)`. `CourtCalibration.courtPoints` is always exactly `[(0,0),(1,0),(0,1),(1,1)]`. The homography maps image → normalized court `[0,1]×[0,1]`.
- **`HomographyService.compute` is scale-agnostic** — it solves the mapping between whatever two ordered point sets it's given. The convention above governs what the VM feeds it and persists.
- **Row-major storage / column-major matrix / `H * columnVector` forward map** — the three-way transpose convention pinned in §2.1.1 and §2.1.2. This is the single most load-bearing correctness decision in the slice.

## 6. Sequence Diagram (text)

**Create/open active match → calibrate → record → end → summary:**
1. Active-match tap (or created-match `onChange`) → `MatchListView` builds one `CameraSessionViewModel(camera: CameraService())`, stores it in `@State`, appends `.cameraSetup(matchId)`.
2. `CameraSetupView` appears → `await cameraVM.startPreview()` → permission granted → `.previewing`; denied → `.permissionDenied` (Settings prompt). "Next" → append `.cornerTap(matchId)`.
3. `CornerTapView`: user taps 4 corners in `[TL,TR,BL,BR]` order → `cameraVM.tapCorner(at:imageSize:)` each (fraction coords). 1..3 → `.tappingCorners(n)`, `homography == nil`. 4th → `.calibrated`, `homography = HomographyService.compute(...)` over the 4 fraction points + unit square.
4. On the 4th tap, `cameraVM.saveCalibration(for: matchId)` writes `Documents/calibrations/{matchId}.json` (FR-V4 — before recording ends). Append `.session(matchId)`.
5. `RecordSessionView` (with `cameraVM != nil`) appears → auto `startRecording(matchId:)` (OQ-6) → `.recording`; `● REC` badge shown. Zone taps + shot recording via `RecordSessionViewModel` are unchanged from Phase 1.
6. End Match → `cameraVM.stopRecording()` → `.done`, **then** `RecordSessionViewModel.endMatch()` → `POST /matches/{id}/end` → route to `.summary`.

**Homography solve + persist (the transpose-critical path):**
1. `HomographyService.compute` builds the 8×9 DLT `A` (double), solves the null vector `h` via `dgesdd_`, normalizes so `h22 == 1`. `h` **is** the row-major 9-vector.
2. simd matrix built from `h` via `init(columns:)` grouping — element `(r,c) == M[c][r] == h[3r+c]`.
3. `CameraSessionViewModel` applies `H * columnVector` for any forward map (Phase-3 convention).
4. `CourtCalibration(homography: H)` init flattens `M[c][r]` back to a row-major `[Float]` — the same array `h` was, closing the loop. AC10a guards that this flatten did not transpose.

## 7. AC → Design coverage matrix

| AC | Satisfied by | Where |
|---|---|---|
| AC1 (identity maps corners to self) | `compute` + round-trip | HomographyService |
| AC2 (offset rect, center→0.5,0.5) | `compute` + `H*columnVector` round-trip | HomographyService |
| AC3 (perspective trapezoid) | `compute` + round-trip | HomographyService |
| AC4 (degenerate/collinear → nil) | rank/round-trip + h22 guard | HomographyService |
| AC5 (wrong count → nil) | count guard | HomographyService |
| AC6 (mismatched counts → nil) | count guard | HomographyService |
| AC7 (calibration round-trip) | Codable `CourtCalibration` | CalibrationStore |
| AC8 (unknown matchId → nil) | `load` returns nil | CalibrationStore |
| AC9 (delete + no-throw-if-absent) | `delete`/`exists` | CalibrationStore |
| AC10 (CGPointCodable + flat 9-array JSON) | `CGPointCodable` + `[Float]` | CalibrationStore |
| AC10a (row-major element order, non-diagonal) | shared `homography:` init flatten | CalibrationStore (values from HomographyService) |
| AC11 (videoURL ends videos/{id}.mov) | `videoURL(for:)` | LocalVideoStore |
| AC12 (exists/delete) | `exists`/`delete` | LocalVideoStore |
| AC13 (initial .permissionPending) | initial state | CameraSessionViewModel |
| AC14 (granted → previewing) | `startPreview` + MockCameraService | CameraSessionViewModel |
| AC15 (denied → .permissionDenied, not previewing) | `startPreview` + mock deny | CameraSessionViewModel |
| AC16 (3 taps not calibrated) | `tapCorner` accumulation | CameraSessionViewModel |
| AC17 (4th tap calibrates; homography == compute) | `tapCorner` auto-advance | CameraSessionViewModel |
| AC18 (taps as fraction coords, TL..BR) | `tapCorner` conversion | CameraSessionViewModel |
| AC19 (startRecording → recording) | `startRecording` + mock | CameraSessionViewModel |
| AC20 (stopRecording → done) | `stopRecording` + mock | CameraSessionViewModel |
| AC21 (saveCalibration persists) | `saveCalibration` via shared init | CameraSessionViewModel + CalibrationStore |
| AC22 (tapCorner before permission = no-op) | OQ-3 guard | CameraSessionViewModel |
| AC23 (full state-machine walk) | all transitions + MockCameraService | CameraSessionViewModel |
| AC24 (xcodebuild build app target) | build-only (env-permitting) | app target |
| AC25 (CameraService #if !os(macOS), excluded from swift test) | guard + inspection | CameraService |
| AC26 (RecordSessionView optional param default nil) | additive init | RecordSessionView |
| AC27 (MatchListView routes through cameraSetup/cornerTap; summary unchanged) | Route cases + switch | MatchListView |
| AC28 (no new dependency) | Package.swift untouched | Package.swift / app target |
| AC29 (HomographyService imports none of AVFoundation/UIKit/CoreImage/Vision) | import discipline | HomographyService |

Every AC1–AC29 (incl. AC10a) maps to at least one task (§ tasks doc). No orphans.

## 8. Verification Gates (spec §10)

- `cd ios/TennisCore && swift test` passes — **the real gate**. **20+ new tests on top of the existing 86 (total 106+), all green.** Budget below.
- `xcodebuild build` of the app target succeeds (compile-only; no simulator). **If the iOS platform destination is unresolvable (no simulator runtime, §2.3), fall back to the `swiftc -typecheck` iOS-SDK compensator** over the app-target sources (Phase-1 Task-8 precedent); record which path was used for Gate 2. A build-env failure is **NOT a code defect** and must not block the green TennisCore work.
- `CameraService.swift` is `#if !os(macOS)`-guarded and excluded from the macOS test build; `swift test` passes without it.
- PR labeled `ai-generated`; never merged to `main` autonomously.

**Test-count budget (clears the 106 gate):**

| Tested component | New tests |
|---|---|
| HomographyService (AC1–AC6: identity, offset-rect round-trip, trapezoid round-trip, degenerate, wrong count, mismatched) | 6 |
| CalibrationStore (AC7–AC10, AC10a) | 5 |
| LocalVideoStore (AC11, AC12) | 2 |
| CameraCapturing/MockCameraService (Task 4 optional) | 1 |
| CameraSessionViewModel (AC13–AC23) | 11 |
| **Total new** | **25** |
| Existing | 86 |
| **Grand total** | **111** ✅ (≥ 106) |

## 9. Risks & Mitigations

- **Silent transpose bug (the central risk).** Three column/row-major conventions collide (§2.1.1 / §5). A transpose slip compiles and passes any diagonal/identity/scaled-rect test. **Mitigations, all baked into tasks:** (a) HomographyService tests MUST include the AC2 offset-rect (non-zero origin → non-diagonal), the AC3 trapezoid (genuine perspective), AND a **forward-mapping round-trip** applying `H * columnVector` and normalizing by `w` — NOT only element-wise comparison against a hand-typed matrix, NOT only identity/scaled-rect (Task 1). (b) The `simd → [Float]` flatten lives in ONE shared `CourtCalibration(homography:)` init so the VM (AC21) and the AC10a store test go through identical code (§2.1.2). (c) AC10a asserts row-major order against a **non-diagonal** homography, the one check the Codable round-trip cannot see (Task 2).
- **A-2 unverified (macOS AVFoundation compile).** The whole testability thesis rests on `AVCaptureVideoPreviewLayer` compiling on macOS, asserted but not proven. **Mitigation:** Task 4 (CameraCapturing + Mock) proves it by compiling `swift test` with the seam present **before** the VM is built (Task 5). Fallback (abstract `previewLayer` behind `#if`) is pre-specified in §2.1.4, not a mid-build surprise.
- **Over-applying the import ban.** §2.2's AVFoundation/UIKit/CoreImage/Vision ban is **HomographyService-only**. `CameraCapturing.swift` legitimately imports AVFoundation. Stated in §2.1.4 so the coder doesn't over-guard.
- **VM cannot ride the Route enum.** `Route` is `Hashable`/String — it can't carry the live `CameraSessionViewModel`. **Mitigation:** MatchListView owns one `@State` VM instance, injected into all three destinations (§2.4). Build-only, so the plan is the only correct spec of it.
- **RecordSessionView regression.** The camera param MUST be a **trailing optional defaulting to nil** so the existing `.session` call site and all Phase-1 tests stay byte-for-byte green (AC26). Zero test edits is the bar.
- **File-store test artifacts on real disk.** Under `swift test`, Documents resolves to a real location. **Mitigation:** injectable `baseDirectory` + per-test temp dir + `tearDown` cleanup (§2.1.3). Never leave artifacts.
- **`@Observable` toolchain risk.** Phase 1 proved `@Observable` builds on this host (SessionStore, the three VMs). Same pattern for `CameraSessionViewModel`.
- **`xcodebuild build` env-blocked (§2.3).** Known, carried from Phase 1. The real gate is `swift test`. Compensator + deviation record per §8.

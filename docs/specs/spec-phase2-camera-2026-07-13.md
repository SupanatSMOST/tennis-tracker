# Spec: iOS App — Camera Recording & Court Calibration (Phase 2)

**Date:** 2026-07-13
**Phase:** Phase 2 (Camera framing + 4-corner tap → homography + record + store video)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Add on-device camera recording and court calibration to the existing match
session flow. After this phase a match session (a) records video from the phone
camera to on-device storage while the user tags shots, and (b) is preceded by a
4-corner court-calibration step that computes and persists a homography mapping
image pixels → normalized court coordinates. The homography is **prep for
Phase 3 CV**; nothing in this phase consumes it beyond persisting it. Zone entry
stays the Phase-1 manual tap (unchanged). All video and calibration data live
entirely on-device. This slice is **iOS-client-only**: no backend changes, no
migrations, no Go work, and `match.source` stays `'manual'`. It builds directly
on the TennisCore foundation and the SwiftUI screens delivered in Phase 1
(`spec-ios-gameplay-2026-07-10.md`), extending — not replacing — the existing
`RecordSessionViewModel` and `NavigationStack`/`Route` routing.

## 2. Critical Constraints (non-negotiable)

### 2.1 Client-only, on-device, `source` stays `manual`

- **Zero backend surface change.** No new routes, no migrations, no Go code.
  End Match reuses the existing Phase-1 `POST /matches/{id}/end` route as-is.
- **Video and calibration are on-device only.** Video → `Documents/videos/{matchId}.mov`;
  calibration → `Documents/calibrations/{matchId}.json`. Neither is uploaded and
  neither is referenced by any API call this slice (`video_ref` is left to its
  backend default, carried from Phase-1 assumption A-5).
- **Shots stay `source: "manual"`.** The homography is computed and stored but is
  never used to classify a shot this slice. No `cv` shots are produced (CV is
  Phase 3). The zone tap grid and `ZoneClassifier` are unchanged from Phase 1.

### 2.2 HomographyService is pure math (the testability contract)

`Calibration/HomographyService.swift` MUST NOT import `AVFoundation`, `UIKit`,
`CoreImage`, or `Vision`. It may import `Foundation`, `CoreGraphics` (for
`CGPoint`), `simd`, and `Accelerate` (if the SVD default in OQ-1 is chosen). This
keeps the entire calibration math surface `swift test`-able on macOS with no iOS
runtime — mirroring the Phase-1 precedent that put `ZoneClassifier` in pure
CoreGraphics so it runs under `swift test`.

### 2.3 macOS `swift test` is the real gate; AVFoundation views are compile-only

Consistent with every prior slice: there is **no iOS simulator runtime on the
build machine**. The real verification gate is `swift test` in `ios/TennisCore`.
Files that import `AVFoundation` for live capture (`CameraService.swift`) or that
are SwiftUI views wrapping `AVCaptureVideoPreviewLayer` (`CameraSetupView`,
`CornerTapView`, and the camera additions to `RecordSessionView`) are verified
**build-only** (`swiftc -typecheck` / `xcodebuild build`), never by a running
test. The per-file tested-vs-typecheck boundary is pinned in §5.

## 3. Divergences from the task sketch (recorded for Gate 2)

The feature intent described the integration in terms that do not match the code
merged to `main`. These are reconciled here so the coder is not misled; none
block the slice.

- **D-1 — Routing is `Route`-enum + `NavigationStack(path:)`, not view pushes.**
  `MatchListView` owns a `@State private var path: [Route]` and a
  `navigationDestination(for: Route.self)` switch (currently `.session` and
  `.summary`). "Push CameraSetupView → CornerTapView → RecordSessionView" is
  therefore expressed as **new `Route` cases** wired into that switch (FR-V5),
  not as imperative view pushes.
- **D-2 — `RecordSessionView` currently takes `(matchClient, matchID, path
  binding)` and constructs its own `RecordSessionViewModel` internally.** The
  intent's "inject an OPTIONAL `CameraSessionViewModel`" is an **additive**
  optional parameter (default `nil`), preserving the existing initializer
  behavior and existing tests/call sites (FR-V3). The internal
  `RecordSessionViewModel` stays; camera is purely additive.
- **D-3 — `CameraSessionViewModel` is a NEW, second ViewModel, distinct from the
  existing `RecordSessionViewModel`.** They are **not merged**:
  `CameraSessionViewModel` owns the camera/calibration state machine (permission,
  preview, corner taps, homography, recording lifecycle);
  `RecordSessionViewModel` continues to own shot recording and End Match. A
  session screen holds both.

## 4. Coordinate & Homography Convention — pinned (no coder discretion)

Homography correctness lives entirely on consistent point ordering and origin.
These are fixed here exactly as §4 of the Phase-1 spec pinned the zone table.

- **Image-point order is always `[TL, TR, BL, BR]`** (top-left, top-right,
  bottom-left, bottom-right), in that index order, in both `tapCorner` collection
  and the persisted `CourtCalibration.imagePoints`.
- **Image points are stored in image-fraction coordinates** — each component in
  `[0, 1]`, `x = px / imageWidth`, `y = py / imageHeight` — with **origin
  top-left** (matches UIKit/image space: `+x` right, `+y` down). `CameraSessionViewModel.tapCorner(at:imageSize:)`
  is responsible for converting the incoming tap point to this fraction space.
- **`HomographyService.compute` takes pixel (or fraction) image points and court
  points as raw `CGPoint`s and is agnostic to their absolute scale** — it solves
  the mapping between whatever two coordinate sets it is given. The *convention*
  above governs what the ViewModel feeds it and persists; the pure-math function
  itself only requires the two point sets be in corresponding order.
- **Court points are always the normalized unit square, in `[TL,TR,BL,BR]`
  order:** `TL=(0,0)`, `TR=(1,0)`, `BL=(0,1)`, `BR=(1,1)`. The computed
  homography therefore maps image coordinates → normalized court coordinates
  `[0,1] × [0,1]`. `CourtCalibration.courtPoints` is always exactly
  `[(0,0),(1,0),(0,1),(1,1)]`.

## 5. Acceptance Criteria

Each criterion is independently verifiable. **Tested ACs** are proven by
`swift test` (macOS, XCTest, hermetic). **Build-only ACs** are proven by
`xcodebuild build` / `swiftc -typecheck` + inspection (no simulator this slice).
Target: **20+ new tests on top of the existing 86 (total 106+), all green.**

Per-file verification boundary:

| File | Verified by |
|---|---|
| `Calibration/HomographyService.swift` | `swift test` |
| `Calibration/CalibrationStore.swift` | `swift test` |
| `Calibration/CameraSessionViewModel.swift` | `swift test` (with `MockCameraService`) |
| `Camera/CameraCapturing.swift` (protocol) | `swift test` (compiles on macOS) |
| `Camera/MockCameraService.swift` | `swift test` |
| `Camera/LocalVideoStore.swift` | `swift test` |
| `Camera/CameraService.swift` | build-only (`#if !os(macOS)`, not compiled on macOS) |
| `Views/CameraSetupView.swift` | build-only |
| `Views/CornerTapView.swift` | build-only |
| `Views/RecordSessionView.swift` (camera additions) | build-only |
| `Views/MatchListView.swift` (new `Route` cases) | build-only |

### TennisCore — HomographyService (`swift test`)
- [ ] AC1: **Identity.** With `imagePoints == courtPoints == [(0,0),(1,0),(0,1),(1,1)]`,
  `compute` returns a non-nil matrix that maps each of the four corners to itself
  (within a small float epsilon, e.g. `1e-4`).
- [ ] AC2: **Offset scaled rectangle.** With image points forming an axis-aligned
  rectangle with a non-zero origin (e.g. corners of `(100,50)-(1920,1080)` in
  `[TL,TR,BL,BR]` order) and the unit-square court points, the returned matrix
  maps the image TL to (0,0), TR to (1,0), BL to (0,1), BR to (1,1) within
  epsilon, and maps the image center to `(0.5, 0.5)`. (A non-zero origin is
  chosen deliberately: a rectangle at the origin yields a diagonal matrix that is
  transpose-invariant and so cannot distinguish the row/col-major bug in AC10a.)
- [ ] AC3: **Perspective (non-affine) quad.** With four image points forming a
  trapezoid (no three collinear), `compute` returns a non-nil matrix that maps
  the four inputs to the four unit-square corners within epsilon. (Guards that
  the solver handles genuine perspective, not just affine.)
- [ ] AC4: **Degenerate → nil.** Three or four collinear image points (e.g.
  `(0,0),(1,1),(2,2),(3,0)`) return `nil`.
- [ ] AC5: **Wrong count → nil.** Fewer than 4 or more than 4 point pairs (either
  list) return `nil`. Exactly 4 pairs is required.
- [ ] AC6: **Mismatched counts → nil.** `imagePoints.count != courtPoints.count`
  returns `nil`.

### TennisCore — CalibrationStore (`swift test`)
- [ ] AC7: **Round-trip.** `save` a `CourtCalibration` for `matchId`, then `load`
  for the same `matchId`, returns an equal value (same `imagePoints`,
  `courtPoints`, and 9-element `homographyMatrix`, within float epsilon).
- [ ] AC8: **Wrong matchId → nil.** `load` for a `matchId` that was never saved
  returns `nil` (not a throw, not a crash).
- [ ] AC9: **Delete.** After `delete(for: matchId)`, a subsequent `load` returns
  `nil` and `exists` is false; `delete` on a nonexistent calibration does not
  throw.
- [ ] AC10: **CGPointCodable JSON shape.** A `CourtCalibration` encodes each point
  as `{"x":<double>,"y":<double>}` and `homographyMatrix` as a flat 9-element
  JSON number array (row-major), decodable back to an equal value.
- [ ] AC10a: **Row-major element order (pinned, load-bearing).** For a **known
  non-diagonal** homography (use the AC2 offset rectangle or the AC3 trapezoid,
  where translation/perspective entries move position under transpose), the
  9-element `homographyMatrix` array equals the expected row-major flattening
  within epsilon: index 0..8 == `[h00,h01,h02, h10,h11,h12, h20,h21,h22]` with
  `h22 == 1.0` (per FR-H1 normalization). This is the one AC that distinguishes
  row-major from `simd`'s native column-major memory layout (A-5) — a bug the
  round-trip in AC7/AC10 cannot see. Placed with the store because the store owns
  the persisted `[Float]`; the values come from `HomographyService.compute`.

### TennisCore — LocalVideoStore (`swift test`)
- [ ] AC11: **URL construction.** `videoURL(for: matchId)` returns a file URL
  ending in `videos/{matchId}.mov` under the app Documents directory.
- [ ] AC12: **exists / delete.** For a matchId with no file, `exists` is false;
  after a file is written at `videoURL(for:)`, `exists` is true; after
  `delete(for:)`, `exists` is false; `delete` on a missing file does not throw.

### TennisCore — CameraSessionViewModel + MockCameraService (`swift test`)
- [ ] AC13: **Initial state.** A fresh `CameraSessionViewModel` is in
  `.permissionPending`.
- [ ] AC14: **Permission granted → previewing.** With a `MockCameraService` stubbed
  to grant permission, `startPreview(camera:)` transitions to `.previewing`.
- [ ] AC15: **Permission denied path (OQ-2).** With the mock stubbed to deny
  permission, `startPreview(camera:)` transitions to the denied representation
  chosen in OQ-2 (default: a `.permissionDenied` terminal state) and does **not**
  reach `.previewing`.
- [ ] AC16: **Three taps do NOT calibrate.** From `.previewing`, three
  `tapCorner(at:imageSize:)` calls leave the VM in `.tappingCorners(count: 3)`;
  `homography` is still `nil`; the state is not `.calibrated`.
- [ ] AC17: **Fourth tap calibrates.** A fourth `tapCorner` auto-advances to
  `.calibrated`, and `homography` is a non-nil `simd_float3x3` equal to
  `HomographyService.compute` over the four accumulated fraction-points and the
  unit-square court points.
- [ ] AC18: **Taps stored as fraction coords in `[TL,TR,BL,BR]` order.** Given four
  taps at pixel points with a known `imageSize`, the accumulated image points are
  the pixel points divided by `imageSize` (per §4), in tap order.
- [ ] AC19: **startRecording → recording.** From `.calibrated`,
  `startRecording(matchId:)` resolves the URL via `LocalVideoStore`, calls
  `camera.startRecording(to:)` (the mock writes an empty file there), and
  transitions to `.recording`.
- [ ] AC20: **stopRecording → done.** From `.recording`, `stopRecording()` calls
  `camera.stopRecording()` (resolves immediately in the mock) and transitions to
  `.done`.
- [ ] AC21: **saveCalibration persists.** After calibration,
  `saveCalibration(for: matchId)` writes a `CourtCalibration` retrievable by
  `CalibrationStore.load(for: matchId)` with the VM's four image points, the
  unit-square court points, and the 9 homography elements.
- [ ] AC22: **tapCorner before permission (OQ-3).** Calling `tapCorner` while in
  `.permissionPending` follows the OQ-3 default (no-op: state unchanged, no
  point accumulated), so an out-of-order UI cannot corrupt calibration.
- [ ] AC23: **Full state-machine walk.** A single test drives
  `.permissionPending → .previewing → .tappingCorners(1..3) → .calibrated →
  .recording → .done` in order, asserting each transition, using
  `MockCameraService`.

### App target / AVFoundation — build-only (`xcodebuild build`, inspection)
- [ ] AC24: `xcodebuild build` of the `TennisShotTracker` app target succeeds
  (compile-only; no simulator, no test run) with the new views and the camera
  additions to `RecordSessionView`.
- [ ] AC25: `CameraService.swift` is wrapped in `#if !os(macOS)` and is **not**
  compiled into the macOS `swift test` build (verified by `swift test` still
  passing and by inspection); `MockCameraService` compiles on all platforms.
- [ ] AC26: By inspection, `RecordSessionView`'s existing initializer still works
  with the camera VM absent (the new `CameraSessionViewModel?` param defaults to
  `nil`), so all existing Phase-1 tests and call sites are unaffected (D-2).
- [ ] AC27: By inspection, `MatchListView`'s active-match tap now routes through
  the new camera-setup `Route` case(s) into corner-tap and then the recording
  session; the ended-match path (`.summary`) is unchanged (D-1).
- [ ] AC28: By inspection, no new third-party dependency is added to
  `Package.swift` or the app target beyond what Phase 1 declared.
- [ ] AC29: By inspection, `HomographyService.swift` imports none of
  `AVFoundation`, `UIKit`, `CoreImage`, `Vision` (§2.2).

## 6. Functional Requirements

### iOS (Swift) — TennisCore

- **FR-C1 — `Camera/CameraCapturing.swift` (protocol).** Defines the capture
  seam consumed by `CameraSessionViewModel`:
  `var previewLayer: AVCaptureVideoPreviewLayer { get }`,
  `func requestPermission() async -> Bool`, `func startPreview() throws`,
  `func startRecording(to url: URL) throws`,
  `func stopRecording() async throws`, `func stopPreview()`. The protocol must
  compile on macOS (A-2) so the VM and mock are `swift test`-able.
- **FR-C2 — `Camera/CameraService.swift` (concrete, iOS-only).** AVFoundation
  implementation of `CameraCapturing`, wrapped in `#if !os(macOS)`, not compiled
  on macOS (AC25). Records to the given URL as a `.mov`. Build-only verified.
- **FR-C3 — `Camera/MockCameraService.swift` (all platforms).** In-memory stub
  implementing `CameraCapturing`, compiled everywhere and used in tests.
  `startRecording(to:)` writes an empty file at the URL; `stopRecording()`
  resolves immediately; `requestPermission()` returns a configurable stubbed
  result. Provides a `previewLayer` that is valid to reference on macOS.
- **FR-C4 — `Camera/LocalVideoStore.swift`.** `struct LocalVideoStore` with
  `static func videoURL(for matchId: String) -> URL`,
  `static func exists(for matchId: String) -> Bool`,
  `static func delete(for matchId: String) throws`. Manages
  `Documents/videos/{matchId}.mov`; creates the `videos/` directory as needed.
  Test isolation per A-4.
- **FR-H1 — `Calibration/HomographyService.swift` (pure math).**
  `static func compute(imagePoints: [CGPoint], courtPoints: [CGPoint]) -> simd_float3x3?`.
  Requires exactly 4 corresponding pairs (else `nil`, AC5/AC6); returns `nil` on
  a degenerate/collinear configuration (AC4). Solves the 8×9 DLT system via SVD
  (solver choice per OQ-1) and returns the homography as `simd_float3x3` (or
  `nil`). **Scale normalization (pinned, load-bearing):** a homography is defined
  only up to a scalar, so `compute` MUST normalize the result so its bottom-right
  entry (`h8`, the `[2][2]` element, row 2 / col 2 in row-major terms) equals
  `1.0`; if `|h8| < 1e-9` after solving, return `nil` (a valid court homography
  never has a zero bottom-right entry). Without this pin, two correct solvers
  persist matrices differing by a constant and Phase 3 inherits an unpinned
  convention. No AVFoundation/UIKit/CoreImage/Vision import (2.2, AC29).
- **FR-H2 — `Calibration/CalibrationStore.swift`.** Persist/load one
  `CourtCalibration` per `matchId` at `Documents/calibrations/{matchId}.json`.
  `CourtCalibration: Codable { let matchId: String; let imagePoints:
  [CGPointCodable]; let courtPoints: [CGPointCodable]; let homographyMatrix:
  [Float] }` (9 elements, row-major).
  `CGPointCodable: Codable { var x: Double; var y: Double }`. `load` returns
  `nil` (not throw) for an unknown `matchId` (AC8). `delete` removes the file and
  is a no-op if absent (AC9). Test isolation per A-4.
- **FR-VM1 — `Calibration/CameraSessionViewModel.swift` (`@Observable`).** Owns the
  camera/calibration state machine (D-3):
  `.permissionPending → .previewing → .tappingCorners(count: Int) → .calibrated →
  .recording → .done`, plus the OQ-2 denied representation. Methods:
  - `startPreview(camera:)` — requests permission then starts preview; on grant →
    `.previewing`, on denial → OQ-2 default state.
  - `tapCorner(at point: CGPoint, imageSize: CGSize)` — accumulates up to 4 taps
    in `[TL,TR,BL,BR]` order as image-fraction coords (§4); auto-advances to
    `.calibrated` on the 4th tap and computes `homography` via
    `HomographyService.compute`. Before permission, follows OQ-3 (default no-op).
  - `startRecording(matchId:)` — resolves the URL via `LocalVideoStore`, calls
    `camera.startRecording(to:)`, transitions to `.recording`.
  - `stopRecording()` — calls `camera.stopRecording()`, transitions to `.done`.
  - `saveCalibration(for matchId:)` — writes a `CourtCalibration` via
    `CalibrationStore`.
  Takes an injected `CameraCapturing` (the mock in tests, `CameraService` on
  device), mirroring the Phase-1 VM dependency-injection pattern.

### iOS (Swift) — app target (build-only)

- **FR-V1 — `Views/CameraSetupView.swift`.** Live camera preview via a
  `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`; a corner-bracket
  guide overlay; framing-guidance text; a "Next" action that advances to the
  corner-tap step. Driven by `CameraSessionViewModel`. Build-only (AVFoundation).
- **FR-V2 — `Views/CornerTapView.swift`.** Sequential 4-corner tap with prompts
  ("Tap Top-Left corner" … "Tap Bottom-Right corner"), a colored dot at each
  tapped point, and a "Redo" button (resets accumulated taps). On the 4th tap,
  once `homography` is computed, advances into the recording session. Driven by
  `CameraSessionViewModel`; tap coordinates handed to `tapCorner(at:imageSize:)`
  in the §4 convention. Build-only.
- **FR-V3 — `Views/RecordSessionView.swift` (additive change).** Add an optional
  `CameraSessionViewModel?` initializer parameter defaulting to `nil` (D-2): when
  present, show an inline camera preview thumbnail and a `● REC` badge while
  recording; when `nil`, behavior is exactly as Phase 1 (no camera UI, existing
  tests unaffected — AC26). The zone tap grid and shot recording via
  `RecordSessionViewModel` are unchanged. End Match additionally calls the camera
  VM's `stopRecording()` (when present) **before** the existing
  `RecordSessionViewModel.endMatch()` posts to the backend.
- **FR-V4 — `saveCalibration` call site.** The calibration is persisted via
  `CameraSessionViewModel.saveCalibration(for:)` once computed (at the transition
  out of corner-tap into the recording session), so a crash mid-session does not
  lose it. Exact placement is a view-layer detail; the requirement is that a
  completed calibration is on disk before recording ends.
- **FR-V5 — `Views/MatchListView.swift` routing (additive change).** Extend the
  `Route` enum with the camera-setup and corner-tap cases (e.g.
  `.cameraSetup(String)`, `.cornerTap(String)`) and wire them into the existing
  `navigationDestination(for: Route.self)` switch (D-1). An **active** match tap
  now routes `.cameraSetup → .cornerTap → .session` instead of directly to
  `.session`; the created-match path routes the same way. The **ended**-match
  path (`.summary`) is unchanged.

### Backend (Go)
- N/A for this slice. No routes, no handlers, no migrations, no Go code (§2.1).
  End Match reuses `POST /matches/{id}/end` exactly as delivered in Phase 1.

### CV Pipeline (Python)
- N/A for this slice. The homography is computed and persisted as **prep** for
  Phase 3; no CV/CoreML runs here (§2.1).

## 7. Data Model Changes

**None.** No database, schema, or migration changes — this is a client-only,
on-device slice (§2.1). `match.source` stays `'manual'`; `video_ref` is left to
its backend default (Phase-1 A-5). The only new persisted data is on-device and
outside the database:

- `Documents/videos/{matchId}.mov` — recorded session video (via
  `LocalVideoStore`).
- `Documents/calibrations/{matchId}.json` — one `CourtCalibration` per match
  (via `CalibrationStore`).

## 8. API Contract

**None new.** No endpoint is added, changed, or newly consumed this slice. The
only backend interaction is the existing `POST /matches/{id}/end` (Phase-1
route 4), called unchanged by `RecordSessionViewModel.endMatch()` after the
camera VM's `stopRecording()`. No request now carries video or calibration data.

## 9. Non-Functional Requirements

### Security / privacy
- Video and calibration never leave the device (§2.1) — consistent with the
  locked "CV location: on-device only (v1)" and "privacy, offline" decisions.
- Camera use requires an `NSCameraUsageDescription` Info.plist string; the app
  requests permission via `CameraCapturing.requestPermission()` before preview.
  Adding the usage-description key is an app-target build detail flagged in A-3.
- No new at-rest secrets; no `.env`; no new credentials.

### Performance
- No latency target. Single-user, post-record CV posture (CV is Phase 3);
  recording is real-time by the OS capture pipeline. The homography solve is a
  one-time 8×9 SVD per calibration — negligible.

### Known technical risk (carried forward)
- No iOS simulator runtime; the app target and AVFoundation views are
  **compile-only** (§2.3). The real gate is `swift test` in TennisCore
  (106+ green). Live camera capture and preview are not exercised by an
  automated test this slice.

## 10. Verification Gates (verbatim)

- `swift test` in `ios/TennisCore` passes — **the real test gate**. 20+ new tests
  on top of the existing 86 (total 106+), all green.
- `xcodebuild build` of the app target succeeds (compile-only; no simulator).
- `CameraService.swift` is `#if !os(macOS)`-guarded and excluded from the macOS
  test build; `swift test` passes without it.
- Branch `feat/phase2-camera` off `main`. No third-party dependencies. PR labeled
  `ai-generated`; never merged to `main` autonomously.

## 11. Open Questions

Gate 1 is pre-approved, so each carries a recommended default the coder follows
unless the human overrides it.

- **OQ-1 — SVD solver for the DLT.** The homography needs the null-space of an
  8×9 (or 9×9 via `AᵀA`) matrix, i.e. an SVD. Options: (a) Accelerate LAPACK
  (`sgesdd_`/`dgesdd_`), (b) a hand-rolled Jacobi SVD, (c) eigen-decomposition of
  `AᵀA`. **Default: (a) Accelerate `dgesdd_`** in double precision then cast to
  `Float` — battle-tested, no third-party dep, available on macOS + iOS, and keeps
  §2.2 clean (Accelerate is not AVFoundation/Vision). If the coder finds the
  LAPACK C-interop noise not worth it, (b) hand-rolled Jacobi is an acceptable
  fallback given the fixed 9×9 size. This is an implementation choice, not a
  contract — the contract is FR-H1's signature and behavior.
- **OQ-2 — Permission-denied state representation.** The state machine as sketched
  has no denied state. **Default: add a terminal `.permissionDenied` case**
  (distinct from `.permissionPending`) that the view renders as a "grant camera
  access in Settings" prompt; `startPreview` never reaches `.previewing` on
  denial (AC15). Alternative: reuse `.permissionPending` plus a separate
  `denied: Bool` flag — rejected as less testable. Confirm the terminal-case
  default.
- **OQ-3 — `tapCorner` before permission / before `.previewing`.** **Default:
  no-op** — a `tapCorner` call while not in `.previewing`/`.tappingCorners`
  leaves state and accumulated points unchanged (AC22), so an out-of-order UI
  cannot corrupt calibration. Alternative: throw/return an error. No-op chosen
  because the UI already gates tapping behind preview; the guard is defensive.
  Confirm no-op vs error.
- **OQ-4 — Image-fraction origin convention.** *Answered in-spec (§4):* origin
  top-left, `+y` down, points in `[TL,TR,BL,BR]` order, court = unit square.
  Listed here only for visibility; no action needed unless the human wants a
  bottom-left origin (which would flip the court `y` mapping).
- **OQ-5 — Redo granularity in CornerTapView.** **Default: "Redo" clears all four
  taps and restarts from Top-Left** (simplest, deterministic). Alternative:
  undo-last-tap. Confirm full-reset vs single-undo.
- **OQ-6 — Recording start timing.** **Default: recording starts on entry to the
  session screen** (i.e. `startRecording` fires when the recording session
  appears, right after calibration), so the whole hitting session is captured.
  Alternative: an explicit "Start Recording" button. Confirm auto-start vs manual.
- **OQ-7 — Calibration/video lifecycle on match delete or re-record.** This slice
  has no match-delete UI and no re-calibration of an existing match. **Default:
  overwrite** — recording a match that already has a `.mov`/calibration
  overwrites both (LocalVideoStore/CalibrationStore write to the fixed per-match
  path). Orphan cleanup is deferred. Confirm overwrite vs guard.

## 12. Assumptions

Explicit assumptions so the coder has no undocumented decision; any can be
overridden by the human.

- **A-1 — Homography is prep only.** Nothing this slice consumes the persisted
  homography beyond writing it. Phase 3 wires it into CV zone classification.
  Storing it now de-risks Phase 3; a wrong-but-persisted matrix has no user-facing
  effect this slice.
- **A-2 — `CameraCapturing` + `AVCaptureVideoPreviewLayer` compile on macOS.**
  `AVCaptureVideoPreviewLayer` is available on macOS, so the protocol, the mock,
  and the VM compile under `swift test`. If, at first compile, the protocol will
  not build on macOS (e.g. an iOS-only type leaks into the signature), the
  offending member must move behind `#if !os(macOS)` or be abstracted — flagged
  because it would change the tested surface. Verify at first compile.
- **A-3 — `NSCameraUsageDescription` added to the app target.** The Info.plist
  gains a camera usage-description string; this is an app-target build change, not
  a code change, and does not affect `swift test`.
- **A-4 — Store test isolation.** `CalibrationStore` and `LocalVideoStore` resolve
  paths under the app Documents directory, which under `swift test` is a real
  on-disk location. Tests must isolate (unique per-test `matchId`s + cleanup in
  `tearDown`, or an injectable base directory). Mirror whatever the existing
  `TokenStore`/store tests do; do not leave test artifacts on disk. If a
  base-directory seam is needed for clean testing, adding one to the two stores is
  an acceptable, flagged addition.
- **A-5 — `simd_float3x3` return; single-precision; column-major trap.** The
  homography is returned as `simd_float3x3` per the sketch. If the SVD is solved
  in double precision (OQ-1 default), it is cast to `Float` at the boundary; float
  epsilon in the ACs accounts for the precision loss. **Trap:** `simd_float3x3` is
  **column-major** in memory, but `CourtCalibration.homographyMatrix` is pinned
  **row-major** (4/FR-H2/AC10a). Flattening the matrix's columns naively yields
  column-major; producing the row-major array requires a transpose (or indexing
  `M[col][row]`). AC10a is the guard against getting this backwards.
- **A-6 — Corner order comes from the UI prompt sequence.** `[TL,TR,BL,BR]` is
  produced by prompting the user in exactly that order (FR-V2). The VM trusts tap
  order; it does not geometrically sort taps into corners. A mis-tapped corner is
  handled by "Redo" (OQ-5), not by auto-correction.
- **A-7 — `courtPoints` always the unit square.** `HomographyService.compute` takes
  `courtPoints` as a parameter for generality/testability, but the app always
  passes `[(0,0),(1,0),(0,1),(1,1)]` and `CourtCalibration.courtPoints` is always
  that (§4). The parameter is not user-configurable this slice.
- **A-8 — ViewModels live in TennisCore.** Consistent with Phase-1 A-9,
  `CameraSessionViewModel` lives in TennisCore (so it is `swift test`-able with
  `MockCameraService`), and the SwiftUI views are thin readers.

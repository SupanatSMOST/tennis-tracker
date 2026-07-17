# Tasks: iOS App — Camera Recording & Court Calibration (Phase 2)

**Plan:** `docs/plans/plan-phase2-camera-2026-07-13.md`
**Spec:** `docs/specs/spec-phase2-camera-2026-07-13.md` (Gate-1 approved)
**Total tasks:** 11
**Branch:** `feat/phase2-camera` off `main`. All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Order (dependency-driven, per the load-bearing sequencing constraints):**
> foundational pure-math + stores (Tasks 1–3: HomographyService → CalibrationStore → LocalVideoStore) → the capture seam + mock that proves A-2 (Task 4) → `CameraSessionViewModel` which depends on all four (Task 5) → the `swift test` gate checkpoint (after Task 5) → build-only views + additive edits (Tasks 6–9) → xcodebuild/typecheck (Task 10) → final gate (Task 11). Tasks 1–5 make `swift test` green — the **real gate** (spec §10, 106+). Views and view edits are additive and last.
>
> **Conventions:** SwiftUI + MVVM; `CameraSessionViewModel` is `@Observable` and IN TennisCore (A-8); async/await for all I/O (no completion handlers); **XCTest** (not swift-testing); conventional commits. Image points are `[TL,TR,BL,BR]` fraction coords (spec §4). Court points are always `[(0,0),(1,0),(0,1),(1,1)]`. `homographyMatrix` is **row-major** `[h00,h01,h02,h10,h11,h12,h20,h21,h22]`, `h22==1`. Each task is one coder pass (≤ ~200 lines new code). **Migration rule (never combine migration + app code) is N/A — no migrations this slice.**
>
> **The seven OQ defaults are LOCKED (plan §0 header). The coder does NOT re-open them.**

---

## Task 1: HomographyService (pure-math DLT/SVD) + transpose-guarding tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Calibration/HomographyService.swift` — `public enum HomographyService { public static func compute(imagePoints: [CGPoint], courtPoints: [CGPoint]) -> simd_float3x3? }`. Imports **only** `Foundation`, `CoreGraphics`, `simd`, `Accelerate` — **MUST NOT import AVFoundation, UIKit, CoreImage, Vision** (AC29). Algorithm exactly per plan §2.1.1: (1) guard both counts == 4 else nil (AC5/AC6); (2) build the 8×9 DLT matrix `A` in **double precision** (two standard rows per pair); (3) solve the null vector `h` via SVD (OQ-1: Accelerate `dgesdd_`, double precision, column-major `A`/`VT` handling); (4) degenerate/collinear → nil via the **pinned singular-ratio criterion `S[7]/S[0] < 1e-6`** (`dgesdd_` returns `S` descending; a collinear set collapses σ7). **DO NOT use a determinant/element-magnitude guard** — the AC2 offset-rect is a *valid* homography with `det ≈ 5.3e-7`, so `abs(det) < 1e-6 → nil` would wrongly reject it (AC4); (5) **scale-normalize** so `h[8]` (h22) == 1.0, else `|h[8]| < 1e-9` → nil; (6) the normalized `h` **is** the row-major 9-vector; (7) build `simd_float3x3(columns:)` grouping `([h0,h3,h6],[h1,h4,h7],[h2,h5,h8])` so element `(r,c) == M[c][r] == h[3r+c]`.
- `ios/TennisCore/Tests/TennisCoreTests/HomographyServiceTests.swift`.
**Depends on:** none (pure math; no stores, no VM)
**Acceptance (AC1–AC6):** `compute` returns a non-nil `simd_float3x3` for identity, offset-rect, and trapezoid inputs, mapping each of the 4 image points to the corresponding unit-square corner within `1e-4`; returns nil for degenerate/collinear (AC4), for count != 4 either list (AC5), and for mismatched counts (AC6). The bottom-right entry is normalized to 1.0.
**Test (CRITICAL — the transpose guard; the test-writer MUST build all three, not just element-wise/identity):**
- **AC1 identity:** `imagePoints == courtPoints == [(0,0),(1,0),(0,1),(1,1)]` → each corner maps to itself within `1e-4`.
- **AC2 offset scaled rect (forward-mapping round-trip, non-diagonal):** image points `(100,50),(1920,50),(100,1080),(1920,1080)` in `[TL,TR,BL,BR]` order + unit-square court. Apply the returned `H` to each image point **as `H * simd_float3(Float(x),Float(y),1)`, normalizing by `p.z`** (the `H * columnVector` convention Phase 3 consumes — NOT `vector * H`): assert TL→(0,0), TR→(1,0), BL→(0,1), BR→(1,1), and the image **center**→(0.5,0.5), all within `1e-4`. A non-zero origin is deliberate — an origin-anchored rect yields a transpose-invariant diagonal matrix that cannot catch the row/col-major bug.
- **AC3 perspective trapezoid (forward-mapping round-trip, non-affine):** four non-collinear trapezoid image points (no three collinear) → apply `H * columnVector` and assert the four inputs land on the four unit-square corners within `1e-4`. Guards genuine perspective, not just affine.
- **AC4 degenerate:** collinear points e.g. `(0,0),(1,1),(2,2),(3,0)` → `nil`.
- **AC5 wrong count:** 3 or 5 pairs (either list) → `nil`.
- **AC6 mismatched counts:** `imagePoints.count != courtPoints.count` → `nil`.
- **DO NOT** rely solely on element-wise comparison against a hand-typed matrix, and **DO NOT** rely solely on identity/scaled-rect — the forward round-trip on AC2 + AC3 is the load-bearing guard.

## Task 2: CalibrationStore + CourtCalibration (shared row-major seam) + row-major-order tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Calibration/CalibrationStore.swift` — per plan §2.1.2: `struct CGPointCodable: Codable, Equatable { var x: Double; var y: Double }`; `struct CourtCalibration: Codable, Equatable { let matchId: String; let imagePoints: [CGPointCodable]; let courtPoints: [CGPointCodable]; let homographyMatrix: [Float] }` (9 elements, **row-major**). **THE shared conversion seam:** `init(matchId:imagePoints:courtPoints:homography H: simd_float3x3)` flattens **row-major** via `for r in 0..<3 { for c in 0..<3 { out.append(H[c][r]) } }` (element `(r,c)` of a column-major simd is `H[c][r]`; `out[3r+c] == H[c][r]`). Provide the Codable-synthesized init too for decode round-trip. `struct CalibrationStore { init(baseDirectory: URL? = nil); func save(_:) throws; func load(for:) -> CourtCalibration?; func exists(for:) -> Bool; func delete(for:) throws }`, path `<base ?? Documents>/calibrations/{matchId}.json`, `calibrations/` created on first save; `load` returns nil (not throw) on unknown id (AC8); `delete` no-op if absent (AC9). `baseDirectory` per plan §2.1.3.
- `ios/TennisCore/Tests/TennisCoreTests/CalibrationStoreTests.swift` — inject a unique temp `baseDirectory` per test; clean up in `tearDown`.
**Depends on:** Task 1 (AC10a asserts against a `HomographyService.compute` matrix)
**Acceptance (AC7–AC10, AC10a):** `save` then `load` for the same matchId returns an equal value (points + 9 elements within epsilon) (AC7); `load` for an unsaved matchId → nil (AC8); after `delete`, `load` → nil and `exists` false, `delete` on absent does not throw (AC9); JSON encodes each point as `{"x":..,"y":..}` and `homographyMatrix` as a flat 9-number array, decodable back to equal (AC10); **AC10a (load-bearing):** for a **non-diagonal** homography (compute the AC2 offset-rect or AC3 trapezoid matrix via `HomographyService.compute`), the constructed `homographyMatrix` equals the expected **row-major** flattening `[h00,h01,h02,h10,h11,h12,h20,h21,h22]` within epsilon, with `h22 == 1.0`.
**Test:** `swift test`: round-trip save/load (AC7); unknown-id nil (AC8); delete + exists + absent-no-throw (AC9); encode a `CourtCalibration` and assert JSON point shape + flat 9-array (AC10); build a `CourtCalibration(homography:)` from a **non-diagonal** compute result and assert index 0..8 equals the hand-derived row-major order with `h22==1.0` — the one test the symmetric Codable round-trip cannot catch (AC10a). All via injected temp `baseDirectory` (no writes to real `~/Documents`).

## Task 3: LocalVideoStore + isolation tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Camera/LocalVideoStore.swift` — per plan §2.1.3: `struct LocalVideoStore { init(baseDirectory: URL? = nil); func videoURL(for matchId: String) -> URL; func exists(for matchId: String) -> Bool; func delete(for matchId: String) throws }`. `videoURL` = `<base ?? Documents>/videos/{matchId}.mov`; `videos/` created as needed; `delete` no-op if absent.
- `ios/TennisCore/Tests/TennisCoreTests/LocalVideoStoreTests.swift` — inject a unique temp `baseDirectory` per test; clean up in `tearDown`.
**Depends on:** none
**Acceptance (AC11, AC12):** `videoURL(for:)` returns a file URL ending in `videos/{matchId}.mov` (AC11); for a matchId with no file `exists` is false; after writing a file at `videoURL(for:)` `exists` is true; after `delete(for:)` `exists` is false; `delete` on a missing file does not throw (AC12).
**Test:** `swift test`: assert the URL suffix (AC11); write an empty file at `videoURL`, assert `exists` toggles true→(delete)→false, and `delete` on absent does not throw (AC12). Injected temp `baseDirectory`; no real `~/Documents` writes.

## Task 4: CameraCapturing seam + MockCameraService + CameraService stub — proves A-2 on macOS
**Layer:** ios (TennisCore) — `swift test` (seam + mock) / build-only (CameraService)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Camera/CameraCapturing.swift` — `import AVFoundation` (the §2.2 import ban is **HomographyService-only** — this file legitimately imports AVFoundation). `public protocol CameraCapturing { var previewLayer: AVCaptureVideoPreviewLayer { get }; func requestPermission() async -> Bool; func startPreview() throws; func startRecording(to url: URL) throws; func stopRecording() async throws; func stopPreview() }` (FR-C1). **Must compile on macOS** (A-2).
- `ios/TennisCore/Sources/TennisCore/Camera/MockCameraService.swift` — **in `Sources/`, NOT `Tests/`** (spec §5). `public final class MockCameraService: CameraCapturing`, mirrors `InMemoryTokenStore`. Configurable stubbed `requestPermission()` result; `startRecording(to:)` writes an empty file at the URL; `stopRecording()` resolves immediately; `previewLayer` returns a plain `AVCaptureVideoPreviewLayer()`. Expose spies as needed (e.g. `startRecordingCalledWith: URL?`, `stopRecordingCalled: Bool`) for AC19/AC20. Compiles on all platforms (FR-C3).
- `ios/TennisCore/Sources/TennisCore/Camera/CameraService.swift` — **entirely wrapped in `#if !os(macOS)`** (AC25). AVFoundation concrete `CameraCapturing`; capture-session setup; records to the given URL as `.mov` (FR-C2). Build-only; NOT compiled under `swift test`.
- (Optional) a tiny `MockCameraServiceTests.swift` asserting the mock's permission stub + empty-file write, counting toward the tally.
**Depends on:** Task 3 (mock's `startRecording` writes to a `LocalVideoStore`-resolved URL in later tests — but the mock itself only needs the URL)
**Acceptance (AC25 + A-2 gate):** `swift test` **compiles and passes with `CameraCapturing.swift` + `MockCameraService.swift` present on macOS** — this **proves A-2** before the VM (Task 5) is built on top. `CameraService.swift` is `#if !os(macOS)`-guarded and **excluded** from the macOS test build (verified by `swift test` still passing and by inspection) (AC25); `MockCameraService` compiles on all platforms. **A-2 fallback (only if `AVCaptureVideoPreviewLayer` will not build on macOS):** abstract `previewLayer` behind a platform typealias or move only that member behind `#if !os(macOS)`, keeping the rest of the seam macOS-testable; flag the deviation.
**Test:** `swift test`: the mock's `requestPermission()` returns its configured value; `startRecording(to:)` creates a file at the URL; `stopRecording()` completes. Primarily this task's gate is "the seam compiles on macOS and swift test is still green."

## Task 5: CameraSessionViewModel (@Observable state machine) + MockCameraService-backed tests
**Layer:** ios (TennisCore) — `swift test`
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Calibration/CameraSessionViewModel.swift` — per plan §2.1.5. `@Observable public final class CameraSessionViewModel`. State enum `CameraSessionState: Equatable { case permissionPending, permissionDenied, previewing, tappingCorners(count: Int), calibrated, recording, done }`. State starts `.permissionPending` (AC13). **Init injects dependencies (signature resolution — plan §2.1.5):** `init(camera: CameraCapturing, calibrationStore: CalibrationStore = CalibrationStore(), videoStore: LocalVideoStore = LocalVideoStore())`; **`startPreview()` is no-arg** (the ACs' `startPreview(camera:)` is read as the injected dependency, per Phase-1 DI precedent). Methods exactly per plan §2.1.5:
  - `startPreview() async` — `await camera.requestPermission()`; true → `camera.startPreview()`, `.previewing` (AC14); false → `.permissionDenied`, never `.previewing` (AC15/OQ-2).
  - `tapCorner(at:imageSize:)` — **OQ-3 guard:** only acts in `.previewing`/`.tappingCorners`, else no-op (AC22). Converts to fraction coords `(point.x/imageSize.width, point.y/imageSize.height)` (§4), appends in tap order (AC18); 1..3 → `.tappingCorners(count:n)`, `homography == nil` (AC16); 4th → `.calibrated`, `homography = HomographyService.compute(imagePoints:, courtPoints: unitSquare)` (AC17).
  - `startRecording(matchId:) throws` — `videoStore.videoURL(for:)`, `camera.startRecording(to:)`, `.recording` (AC19).
  - `stopRecording() async throws` — `camera.stopRecording()`, `.done` (AC20).
  - `saveCalibration(for matchId:) throws` — build `CourtCalibration` through the **shared `homography:` init** (Task 2) with the 4 `imagePoints` (as `CGPointCodable`), unit-square `courtPoints`, computed matrix; `calibrationStore.save(...)` (AC21).
- `ios/TennisCore/Tests/TennisCoreTests/CameraSessionViewModelTests.swift` — use `MockCameraService`, an injected temp-dir `CalibrationStore`/`LocalVideoStore`; clean up in `tearDown`.
**Depends on:** Task 1 (HomographyService), Task 2 (CalibrationStore + shared init), Task 3 (LocalVideoStore), Task 4 (CameraCapturing + MockCameraService)
**Acceptance (AC13–AC23):** fresh VM `.permissionPending` (AC13); mock-grant `startPreview()` → `.previewing` (AC14); mock-deny → `.permissionDenied`, not `.previewing` (AC15); 3 taps → `.tappingCorners(3)`, `homography == nil` (AC16); 4th tap → `.calibrated`, `homography` non-nil and equal to `HomographyService.compute` over the 4 fraction points + unit square (AC17); taps stored as pixel/imageSize fractions in tap order (AC18); `startRecording(matchId:)` → resolves URL, mock writes empty file, `.recording` (AC19); `stopRecording()` → mock resolves, `.done` (AC20); `saveCalibration(for:)` → retrievable via `CalibrationStore.load(for:)` with the 4 image points, unit-square court points, 9 elements (AC21); `tapCorner` while `.permissionPending` = no-op, no point accumulated (AC22); a single test walks `.permissionPending → .previewing → .tappingCorners(1..3) → .calibrated → .recording → .done` asserting each transition (AC23).
**Test:** `swift test` with `MockCameraService` + temp-dir stores: one test per AC13–AC22, plus the full-walk AC23. For AC17, assert `homography` equals `HomographyService.compute(...)` element-wise within epsilon.

> **GATE CHECKPOINT (after Task 5):** `cd ios/TennisCore && swift test` must be fully green with **20+ new tests on top of the existing 86 (106+ total)** — the slice's real gate (spec §10). Budget: 6 (Task 1) + 5 (Task 2) + 2 (Task 3) + 1 (Task 4 optional) + 11 (Task 5) = **25 new → 111 total** ✅. Tasks 6–11 add build-only UI/edits and must not require re-running or editing logic tests; Task 11 re-confirms `swift test` still green.

## Task 6: CameraSetupView (live preview + guide overlay + Next) — build-only
**Layer:** ios (app target) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/CameraSetupView.swift` — per plan §2.2/FR-V1: a `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer` (from `cameraVM.camera.previewLayer` via the seam), a corner-bracket guide overlay, framing-guidance text, a "Next" action that `await cameraVM.startPreview()` on appear and advances `path` to `.cornerTap(matchID)`. Thin reader — no math/state-machine logic. `init(cameraVM: CameraSessionViewModel, matchID: String, path: Binding<[Route]>)`.
**Depends on:** Task 5 (CameraSessionViewModel)
**Acceptance:** by inspection — the view holds no calibration/recording logic (all via `cameraVM`); "Next" appends `.cornerTap(matchID)`; on appear it starts preview. Compiled in Task 10.
**Test:** none runnable (build-only, proven in Task 10). Verification is inspection against FR-V1 + AC24.

## Task 7: CornerTapView (4-corner tap + dots + Redo → session) — build-only
**Layer:** ios (app target) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/CornerTapView.swift` — per plan §2.2/FR-V2: sequential prompts ("Tap Top-Left corner" … "Tap Bottom-Right corner"), a colored dot at each tapped point, a "Redo" button (**OQ-5: clears all four, restarts from Top-Left**). Each tap → `cameraVM.tapCorner(at:imageSize:)` in the §4 convention (pixel point + the preview image size). On the 4th tap, once `cameraVM.homography != nil`, call `cameraVM.saveCalibration(for: matchID)` (FR-V4 — persist before recording ends) and advance `path` to `.session(matchID)`. Thin reader. `init(cameraVM: CameraSessionViewModel, matchID: String, path: Binding<[Route]>)`.
**Depends on:** Task 5 (CameraSessionViewModel)
**Acceptance:** by inspection — taps routed through `cameraVM.tapCorner`; Redo resets accumulated taps (full clear); 4th tap persists calibration then advances to `.session`. No zone/homography math in the view. Compiled in Task 10.
**Test:** none runnable (build-only). Inspection against FR-V2/FR-V4 + OQ-5.

## Task 8: RecordSessionView additive camera param — build-only, ZERO test edits
**Layer:** ios (app target) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/RecordSessionView.swift` — **additive** change per plan §2.3/FR-V3/D-2: add a **trailing optional** init param `cameraVM: CameraSessionViewModel? = nil`. When `nil` → behavior is **exactly Phase 1** (no camera UI; existing tests + the current `.session` call site unaffected — AC26). When non-nil → on appear, auto `startRecording(matchId:)` (OQ-6); show an inline preview thumbnail + `● REC` badge while `state == .recording`; End Match calls `cameraVM.stopRecording()` **before** `RecordSessionViewModel.endMatch()`. The zone tap grid + `RecordSessionViewModel` shot recording are **unchanged**.
**Depends on:** Task 5 (CameraSessionViewModel)
**Acceptance (AC26):** by inspection — the new param is a trailing optional defaulting to `nil`; the existing initializer usage `RecordSessionView(matchClient:matchID:path:)` still compiles unchanged; **no Phase-1 test file is edited** (the zero-test-edit regression bar). Compiled in Task 10.
**Test:** none new; the guarantee is "no Phase-1 test edits and `swift test` still green" (re-confirmed Task 11). Inspection against AC26.

## Task 9: MatchListView new Route cases + shared cameraVM wiring — build-only
**Layer:** ios (app target) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchListView.swift` — per plan §2.4/FR-V5/D-1: extend `Route` with `.cameraSetup(String)` and `.cornerTap(String)`. Add `@State private var cameraVM: CameraSessionViewModel?`. On an **active**-match tap (and in the created-match `onChange`), construct **one** `CameraSessionViewModel(camera: CameraService(), ...)`, store it, and append `.cameraSetup(match.id)` (instead of `.session`). Wire the `navigationDestination(for: Route.self)` switch to inject **that same `cameraVM` instance** into `.cameraSetup → CameraSetupView`, `.cornerTap → CornerTapView`, and `.session → RecordSessionView(..., cameraVM: cameraVM)`. The **ended**-match `.summary` path is **unchanged** (AC27).
- `ios/TennisShotTracker/TennisShotTracker/*` app-target settings — add `NSCameraUsageDescription` string (A-3; Info.plist/build-setting detail, not code).
**Depends on:** Task 6 (CameraSetupView), Task 7 (CornerTapView), Task 8 (RecordSessionView param)
**Acceptance (AC27):** by inspection — an active-match tap routes `.cameraSetup → .cornerTap → .session`; the created-match path routes the same way; the ended-match `.summary` path is unchanged; one shared `cameraVM` instance flows through all three destinations. `NSCameraUsageDescription` present. Compiled in Task 10.
**Test:** none runnable (build-only). Inspection against FR-V5/D-1 + AC27.

## Task 10: Wire new views into .xcodeproj + build the app target
**Layer:** ios (app target / project file) — build-only
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add `CameraSetupView.swift` and `CornerTapView.swift` to the app-target Sources build phase. No change to the TennisCore local-package reference (already linked).
**Depends on:** Tasks 6–9 (view sources exist; edits made)
**Acceptance (AC24, AC28):**
```
xcodebuild build \
  -project ios/TennisShotTracker/TennisShotTracker.xcodeproj \
  -scheme TennisShotTracker \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```
succeeds (compile-only; no runtime; no signing) (AC24). **If the iOS platform destination is unresolvable (no simulator runtime, §2.3 — the known env reality),** fall back to the Phase-1 compensator: `swiftc -typecheck` all `ios/TennisShotTracker/TennisShotTracker/**/*.swift` against the iOS-built `TennisCore` module (`-sdk iphoneos -target arm64-apple-ios17.0`) exits 0. **Record which path was used for Gate 2.** A build-env failure is **NOT a code defect** and must not block the green TennisCore work. No new dependency added to the app target or `Package.swift` (AC28).
**Test:** the `xcodebuild build` command returns exit 0 (or the type-check compensator exits 0, deviation recorded). No simulator run; no `swift test` dependency.

## Task 11: Final gate pass
**Layer:** ios (verification)
**Files to create/modify:** none (verification + any last fixes surfaced by the gates).
**Depends on:** Task 5 (swift test green) and Task 10 (build/typecheck green)
**Acceptance (spec §10):**
1. `cd ios/TennisCore && swift test` → all TennisCore tests pass, **20+ new / 106+ total** (the real gate; AC1–AC23 incl. AC10a). Record the exact new/total count.
2. `xcodebuild build` (Task 10 command) → exit 0 (AC24), OR the type-check compensator exits 0 with the deviation recorded (env-blocked, §2.3).
3. `CameraService.swift` is `#if !os(macOS)`-guarded and excluded from the macOS test build; `swift test` passes without it (AC25).
4. By inspection: AC26 (RecordSessionView optional param, zero Phase-1 test edits), AC27 (MatchListView routing; summary unchanged), AC28 (no new dependency), AC29 (HomographyService imports none of AVFoundation/UIKit/CoreImage/Vision) hold.
Deferred and explicitly NOT gated this slice: iOS simulator/UI tests, iOS CI job, live camera capture/preview rendering, any runtime tap-routing / recording assertions (§2.3). The `xcodebuild build` env-block is a **known deferred Gate-2 item, not a task failure**.
**Test:** run both gate commands; confirm green. Record which ACs each command proves and the new/total test count.

---

## AC → Task coverage matrix

| AC | Task(s) |
|---|---|
| AC1 (identity) | 1 |
| AC2 (offset rect round-trip) | 1 |
| AC3 (perspective trapezoid round-trip) | 1 |
| AC4 (degenerate → nil) | 1 |
| AC5 (wrong count → nil) | 1 |
| AC6 (mismatched counts → nil) | 1 |
| AC7 (calibration round-trip) | 2 |
| AC8 (unknown matchId → nil) | 2 |
| AC9 (delete + no-throw) | 2 |
| AC10 (CGPointCodable + flat 9-array JSON) | 2 |
| AC10a (row-major order, non-diagonal) | 2 (values from 1) |
| AC11 (videoURL suffix) | 3 |
| AC12 (exists/delete) | 3 |
| AC13 (initial .permissionPending) | 5 |
| AC14 (granted → previewing) | 5 |
| AC15 (denied → .permissionDenied) | 5 |
| AC16 (3 taps not calibrated) | 5 |
| AC17 (4th tap calibrates) | 5 |
| AC18 (taps as fraction coords, TL..BR) | 5 |
| AC19 (startRecording → recording) | 5 |
| AC20 (stopRecording → done) | 5 |
| AC21 (saveCalibration persists) | 5 (via 2) |
| AC22 (tapCorner before permission = no-op) | 5 |
| AC23 (full state-machine walk) | 5 |
| AC24 (xcodebuild build) | 10, 11 |
| AC25 (CameraService #if !os(macOS)) | 4, 11 |
| AC26 (RecordSessionView optional param, zero test edits) | 8, 11 |
| AC27 (MatchListView routing; summary unchanged) | 9, 11 |
| AC28 (no new dependency) | 10, 11 |
| AC29 (HomographyService import discipline) | 1, 11 |

Every AC1–AC29 (incl. AC10a) maps to at least one task. A-2 (macOS AVFoundation compile) is proven by Task 4 before Task 5 depends on it. No orphans.

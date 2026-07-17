# Code Review: iOS Camera Recording & Court Calibration (Phase 2)

**Date:** 2026-07-13
**Reviewer:** reviewer (AI)
**Branch:** `feat/phase2-camera` (12 commits ahead of `main`)
**Verdict:** APPROVED WITH FIXES

Real test gate re-run: `swift test` in `ios/TennisCore` → **118 tests, 0 failures**
(86 Phase-1 + 32 new Phase-2). Exceeds the spec target of 106+.

## Spec Compliance

### HomographyService (`swift test`)
- [x] AC1: Identity — forward-map round-trip, eps 1e-4. Implemented + tested.
- [x] AC2: Offset scaled rect (non-zero origin) — forward-maps corners AND center to (0.5,0.5). Load-bearing transpose guard. Tested.
- [x] AC3: Perspective trapezoid — forward-map round-trip on a keystoned quad. Tested.
- [x] AC4: Degenerate → nil — collinear input, singular-ratio `S[7]/S[0] < 1e-6` (NOT a determinant guard). Tested + correctly reasoned in code.
- [x] AC5: Wrong count (either list) → nil. Tested.
- [x] AC6: Mismatched counts → nil. Tested.
- [x] FR-H1: Scale normalization to `h22 == 1.0`, `nil` if `|h8| < 1e-9`. Implemented (lines 153–157) + asserted in AC10a/AC21.

### CalibrationStore (`swift test`)
- [x] AC7: Round-trip save/load. Tested (uses synthesized init, decoupled from AC10a).
- [x] AC8: Unknown matchId → nil (not throw). Tested.
- [x] AC9: Delete + no-op on absent. Tested.
- [x] AC10: JSON shape `{"x":..,"y":..}` + flat 9-array. Tested.
- [x] AC10a: Row-major order against the NON-diagonal AC2 offset-rect matrix, `h22==1.0`, `h02 != h20` non-diagonal assert. Tested.

### LocalVideoStore (`swift test`)
- [x] AC11: `videoURL` ends in `videos/{matchId}.mov` under base dir. Tested.
- [x] AC12: exists/delete lifecycle + no-op on missing. Tested.

### CameraSessionViewModel + MockCameraService (`swift test`)
- [x] AC13–AC23: initial state, permission grant/deny, 3-taps-no-calibrate, 4th-tap-calibrates (matrix equals `HomographyService.compute`), fraction coords in `[TL,TR,BL,BR]` order, start/stop recording, saveCalibration persists, tap-before-permission no-op, full state-machine walk. All tested. Plus OQ-5 `resetCorners()` — 3 extra tests.

### App target / AVFoundation (build-only, inspection)
- [x] AC24: (build-only; orchestrator reported `swiftc -typecheck` exit 0 — not independently re-run, no simulator.)
- [x] AC25: `CameraService.swift` fully wrapped in `#if !os(macOS)`; excluded from macOS test build (confirmed by 118 green tests without it).
- [x] AC26: `RecordSessionView(matchClient:matchID:path:)` unchanged — `cameraVM` is a trailing `CameraSessionViewModel? = nil`. No Phase-1 test file edited (only 5 new Phase-2 test files added).
- [x] AC27: `.cameraSetup → .cornerTap → .session` wired in BOTH `MatchListView` and `TabShellView`; both switches exhaustive over all 4 Route cases; `.summary` (ended match) unchanged.
- [x] AC28: `Package.swift` untouched; deps `[]` / `["TennisCore"]`. No third-party dep.
- [x] AC29: `HomographyService.swift` imports only `Foundation`, `CoreGraphics`, `simd`, `Accelerate` — none of AVFoundation/UIKit/CoreImage/Vision.
- [x] FR-V4: `saveCalibration(for:)` fires on the 4th tap in `CornerTapView.handleTap` BEFORE `path.append(.session)` — calibration is on disk before recording even starts.

## Findings

### [MEDIUM] Info.plist — missing `NSCameraUsageDescription` (AUTO-FIXED)
- **Location:** `ios/TennisShotTracker/Info.plist`
- **Risk:** The app target has `GENERATE_INFOPLIST_FILE = NO` + `INFOPLIST_FILE = Info.plist`, so the physical plist is authoritative. It lacked `NSCameraUsageDescription`. On iOS, `AVCaptureDevice.requestAccess(for: .video)` (called by `CameraService.requestPermission()`) throws an `NSException` and crashes immediately without this key — i.e. the phase's headline feature crashes on first use.
- **Why it slipped:** Spec A-3 pre-scoped this as an app-target build detail that "does not affect `swift test`"; the build-only verification posture (no simulator runtime this slice) could not catch it. No AC covers it, so it does not sink the verdict.
- **Fix applied:** Added `NSCameraUsageDescription` with a user-facing purpose string. Verified with `plutil -lint` → OK. **Flagging for Gate 2 human visibility** since it was masked by build-only verification.

### [WARN] HomographyServiceTests / CalibrationStoreTests — transpose is correct, but one belt-and-suspenders test is worth adding for Phase 3
- **Location:** AC17 and AC10a both derive their expected value from the same `simd_float3x3` using `H[c][r]` indexing.
- **Analysis (not a defect):** The transpose IS correct. simd `matrix * vector` sums columns, so mathematical element (r,c) = `H[c][r]`; the store's seam `out[3r+c] = H[c][r]` is therefore provably row-major, and AC2/AC3 forward-map a non-diagonal H, so they genuinely catch a `compute()` transpose. AC10a additionally catches the likely real flatten bug (`out[3c+r]`).
- **Residual gap:** No test reconstructs H directly from the persisted `[Float]` (reading `matrix[3r+c]` as element (r,c)) and forward-maps a corner. That is the only path that would fully pin the persisted convention independent of the simd handle — valuable because Phase 3 consumes the persisted array, not the in-memory matrix.
- **Suggestion (coder, optional, non-blocking):** Add one CalibrationStore test: load the persisted matrix, build `simd_float3x3` via `H[c][r] = m[3r+c]`, forward-map the AC2 image corners, assert they hit the unit square. Belt-and-suspenders for the Phase-3 boundary.

## Auto-fixes Applied
- `ios/TennisShotTracker/Info.plist`: added `NSCameraUsageDescription` usage string (A-3 / §9 NFR). Validated with `plutil -lint`.

## Convention & Constraint Adherence
- SwiftUI + MVVM: views are thin readers — `CameraSetupView`/`CornerTapView` hold zero calibration/homography/state-machine logic; all flows through `CameraSessionViewModel`. `CornerTapView`'s local `tapLocations`/`previewSize` are view-render state (dot positions, geometry), not business logic.
- `@Observable` VM (`CameraSessionViewModel`). Async/await throughout; the only completion-handler bridge is `CameraService.stopRecording()` wrapping the AVFoundation `AVCaptureFileOutputRecordingDelegate` callback via `withCheckedThrowingContinuation` — inherently callback-based and correctly bridged.
- pbxproj intentionally NOT edited: project uses `PBXFileSystemSynchronizedRootGroup` (files auto-included). Confirmed correct — not a defect. (Note: the Info.plist edit is a content change to an existing file, so it needs no pbxproj entry.)
- Conventional commits: all 12 commits follow `type(scope): message`.
- No backend / migration / cv changes. `match.source` stays manual; no new API surface.
- `try?`/error-swallow sites (`startPreview`, `videoURL` dir creation, `saveCalibration` in CornerTapView) are all marked with `ponytail:` comments documenting the ceiling and upgrade path — deliberate, acceptable.

## Summary
Phase 2 is correct, well-tested, and adheres to every locked constraint. The
highest-risk area — the three colliding column/row-major conventions in the
homography seam — is provably correct and guarded by forward-mapping round-trips
and the non-diagonal AC10a assert. The one real defect (missing
`NSCameraUsageDescription`, a guaranteed on-device crash masked by build-only
verification) has been auto-fixed and lint-validated. Recommend merge after Gate 2
notes the plist fix and considers the optional persisted-matrix round-trip test
for Phase 3 hardening.

# Security Audit: Phase 2 — iOS Camera + Court Calibration

**Date:** 2026-07-13
**Auditor:** security-auditor (AI)
**Branch:** `feat/phase2-camera`  (diff base: `main`, 22 files)
**Scope:** CLIENT-ONLY iOS slice. No backend, no migrations, no Go, no new API calls, no new dependencies (Package.swift unchanged).
**Verdict:** PASS

## Scope & Methodology

Diff obtained via `git diff main...feat/phase2-camera`. The changeset is clean (no cross-history phantom files in this repo). All changed Swift files were read in full:

- TennisCore package: `Calibration/HomographyService.swift`, `Calibration/CalibrationStore.swift`, `Calibration/CameraSessionViewModel.swift`, `Camera/CameraCapturing.swift`, `Camera/MockCameraService.swift`, `Camera/CameraService.swift`, `Camera/LocalVideoStore.swift`.
- App target (build-only): `Views/CameraSetupView.swift`, `CornerTapView.swift`, `RecordSessionView.swift`, `MatchListView.swift`, `TabShellView.swift`; `Info.plist` (+`NSCameraUsageDescription`).
- Tests + docs (not security-relevant).

Backend was PASS in prior slices and is UNCHANGED here — not re-audited (per task).

## OWASP Applicability

This is an on-device client slice with **zero new network surface**. The following web categories are **N/A** and no findings are forced:

- A01 Broken Access Control / A07 Auth — no auth code touched (JWT/Keychain unchanged from Phase 1).
- A03 Injection / A10 SSRF — no DB, no new HTTP requests, no URL construction from user input.
- A02 Cryptographic Failures — no crypto introduced.
- A08 Deserialization — JSON `Codable` only, deserialising the app's own `CourtCalibration` written by the same app (no untrusted source).

Applicable concerns for this slice: on-device file handling (CWE-22/23), secrets, privacy posture, error-message leakage, AVFoundation sandbox correctness. All addressed below.

## Findings

### [INFO] CWE-23 — matchId interpolated into file paths (path traversal)

- **Files:** `CalibrationStore.swift:120` `appendingPathComponent("\(matchId).json")`; `LocalVideoStore.swift:44` `appendingPathComponent("\(matchId).mov")`
- **Analysis:** `matchId` reaches these stores from `CameraSessionViewModel` / views, which receive it from `Route.cameraSetup/cornerTap/session(String)`. The value originates in `MatchListView` from `match.id` and `viewModel.createdMatch.id` — server-issued UUIDs from the Phase 1 backend, constrained to `[0-9a-f-]`. A UUID cannot contain `/` or `..`, so `appendingPathComponent` cannot escape `Documents/calibrations/` or `Documents/videos/`.
- **Risk:** Not exploitable given the current UUID provenance. Consistent with the prior-slice classification (INFO / non-exploitable CWE-23) — confirmed, no change.
- **Note for Gate 2:** This is a defense-in-depth observation, not a required fix. If a future slice ever sources a match identifier from user input or an untrusted response, add a UUID-shape validation at the store boundary before path interpolation.

### [INFO] Privacy — "never leaves the device" is precise only w.r.t. network, not backups

- **Files:** `CalibrationStore.swift:108-110`, `LocalVideoStore.swift:29-31` (both write under `Documents/`)
- **Analysis:** Verified there is **no upload path** — no `URLSession`/`URLRequest`/`dataTask`/`http(s)` in any changed file; camera output is written to a local `.mov` and calibration to local JSON only. This satisfies the "on-device only, privacy" locked decision at the network layer.
- **Caveat:** Files under `Documents/` are, by iOS default, included in iCloud and iTunes/Finder device backups. So "never leaves the device" is accurate for *network egress* but not strictly for *backups* — the user's own video/calibration may replicate to their own iCloud backup.
- **Risk:** Low/none for a single-user personal app (backup to the owner's own iCloud is often desired for device restore). Documented so the claim is precise.
- **Note for Gate 2:** If strict on-device-only is required, set `URLResourceValues.isExcludedFromBackup` on the `videos/` and `calibrations/` directories. Not required to ship.

### [INFO] Sandbox posture is correct (supports privacy decision)

- Both stores resolve to `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]` — the app-private sandbox container, not a world-readable/shared or app-group location. `CameraService.startRecording(to:)` writes to the URL supplied by `LocalVideoStore.videoURL(for:)`, i.e. the same sandboxed `Documents/videos/` path — no writes outside the sandbox.
- `Info.plist` contains **no** `UIFileSharingEnabled` and **no** `LSSupportsOpeningDocumentsInPlace`, so `Documents/` is **not** exposed through the Files app. Addresses focus item #6 (AVFoundation not writing to a shared location).

### [INFO] Error handling — `try?` swallow patterns reviewed, no security-relevant masking

- `CalibrationStore.load(for:)` returns `nil` on missing/corrupt file (spec'd, AC8) — swallows only decode/read failures of the app's own file; no sensitive state hidden.
- `LocalVideoStore.videoURL(for:)` swallows directory-creation error via `try?` (ponytail-annotated); a real failure surfaces at the subsequent camera write.
- `CameraSessionViewModel.startPreview()` swallows `startPreview()` error via `try?`; permission denial is still correctly routed to `.permissionDenied` before any capture.
- `CornerTapView.handleTap` swallows a post-4th-tap `saveCalibration` error (ponytail-annotated); worst case is no CV overlay in Phase 3, not a security issue.
- `CameraServiceError.errorDescription` strings are static, human-readable, and leak no paths, tokens, or internal state. No `err.Error()`-style raw-error exposure to a user surface.

### Info.plist (scope clarification, not a finding)

- The Phase-2 diff adds exactly one key: `NSCameraUsageDescription` — a clear, purpose-limited camera permission string. Correct.
- The `NSAppTransportSecurity` localhost insecure-HTTP exception and `TENNIS_API_BASE_URL` (`http://localhost:8080`) are **pre-existing Phase-1 lines**, not part of this slice. They are out of scope here and are **not** a Phase-2 regression.

## Secrets & Dependencies

- **Secrets scan (Swift):** Clean — no hardcoded api-key/secret/password/token/credential literals in changed files.
- **`.env`:** Clean — only `.env.example` (a template, no secrets) is tracked; no real `.env` committed.
- **Private keys:** Clean.
- **Token in UserDefaults:** Clean — none introduced.
- **Force-unwrap on security paths (`.token!`/`.jwt!`/`.userId!`):** Clean.
- **New third-party dependencies:** None — `Package.swift` unchanged (AC28).

## Privacy Posture Summary

- Camera access gated: `NSCameraUsageDescription` present; `CameraSessionViewModel.startPreview()` calls `requestPermission()` and routes denial to a terminal `.permissionDenied` state before any `startPreview()`/`startRecording()` — no capture without user grant. Consistent with the locked on-device/privacy decision.
- No network egress of video or calibration (see INFO above for the backup caveat).

## Verdict

**PASS.** No CRITICAL/HIGH/MEDIUM findings. The path-traversal surface is bounded by server-issued UUIDs (INFO, confirms prior slice), the sandbox/permission posture is correct, and no secrets or new dependencies were introduced. Three INFO items (UUID-boundary hardening, backup-exclusion, and the precise wording of the privacy claim) are documented for Gate 2 consideration and do not block the PR.

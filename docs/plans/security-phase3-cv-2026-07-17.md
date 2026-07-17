# Security Audit: Phase 3 — CV Integration (on-device)

**Date:** 2026-07-17
**Auditor:** security-auditor (AI)
**Branch:** `feat/phase3-cv`  (diff base: `origin/main`, 25 files, +3596)
**Scope:** 17 in-scope commits `773d8ed..cfc5576`. Python `cv/` build tooling +
TennisCore `CV/` package (protocols, `CVPipeline`, `PostProcessingViewModel`,
`FrameExtractor`, `BallTrackerInference`, `BounceDetectorInference`) + app-target
SwiftUI views. CV is **on-device only** — no backend, no migration, no Go, no new
API endpoint. The pipeline reuses exactly one existing authenticated route:
`POST /matches/{id}/shots` with `source:'cv'` via the Phase-1 `MatchClient`
(`Authorization: Bearer <token>` from Keychain — no new auth code).
**Verdict:** **PASS** — no CRITICAL or HIGH findings. Does not route to coder.

## Requirements baseline (audited against)

- **spec §9 — Configuration/secrets:** "No new config, no secrets, no `.env`.
  Model weights downloaded out-of-band (Drive IDs in `SPIKE_RESULT.md`), never
  committed." — **CONFIRMED** (Findings §Secrets, §Weights).
- **spec §9 — Security/privacy:** "CV runs on-device only. The `.mov` and
  homography never leave the device; only the derived six-value zone strings are
  submitted over the existing authenticated route." — **CONFIRMED** (Findings §Privacy,
  §Input validation).
- **CLAUDE.md AC29 / plan:** no new third-party Swift dependency. — **CONFIRMED**
  (`Package.swift` unchanged).

## OWASP applicability

On-device client slice reusing one pre-existing authenticated route; the only new
runtime "server" surface is a local CoreML inference chain over a local `.mov`.
Web categories forced N/A (no new code touches them): A01/A07 auth (JWT/Keychain
unchanged, inherited from `MatchClient`), A03 injection / A10 SSRF (no DB, no new
HTTP request or URL built from user input), A02 crypto (none introduced), A08
deserialization at runtime (Swift `Codable` on the app's own `CourtCalibration`
only). Applicable concerns — secrets, committed binaries, on-device file/path
handling (CWE-22/23), model-load failure posture, privacy/egress, input validation
of the submitted zone, ML supply chain, and one build-time deserialization
(`torch.load`, CWE-502) — are covered below.

## Findings

| # | Severity | CWE | Area | Blocking |
|---|----------|-----|------|----------|
| 1 | LOW | CWE-502 | `torch.load` without `weights_only` in `convert_models.py` | No |
| 2 | INFO | — | Unbounded (`>=`) dependency floors, no lockfile | No |
| 3 | INFO | CWE-23 | `matchId` interpolated into local file paths | No |
| 4 | INFO | — | `Documents/` files included in iCloud/device backups | No |
| 5 | INFO | — | Test-fixture token literal in test file | No |

### [LOW] CWE-502 — `torch.load` without `weights_only=True`

- **File:** `cv/convert_models.py:205` — `state = torch.load(str(ball_path), map_location="cpu")`
- **Analysis:** Python pickle deserialization can execute arbitrary code on load. The
  input is `ball_track.pt`, a Phase-0 weight the developer downloads manually from a
  Drive ID (README §2) and places in the gitignored `cv/models/`. This is a **local,
  build-time-only tool** run by the developer on a trusted, manually-obtained file —
  not an on-device or server path, and not reachable by any untrusted input. Hence LOW,
  not HIGH.
- **Recommendation (near-free, non-blocking):** pass `weights_only=True`. The result is
  fed straight into `model.load_state_dict(state)`, so it is a state-dict and fully
  compatible; this also makes behaviour deterministic across the `torch>=2.0` floor
  (the default flips to `True` in torch 2.6). Optionally record a SHA256 of the expected
  weight so a swapped Drive file is detected before load — the stronger supply-chain
  hardening. Gate-2 consideration.

### [INFO] Unbounded dependency version floors, no lockfile

- **File:** `cv/requirements.txt` — `coremltools>=8.0`, `torch>=2.0`, `catboost>=1.2`, `numpy>=1.24`
- **Analysis:** The floors themselves are reasonable and current (none sit in a
  known-vuln range). The supply-chain note is the shape of the constraint: `>=` with
  **no upper bound and no lockfile** means a future or compromised release of any of
  these heavy ML packages satisfies the constraint on a fresh `pip install`. These
  deps are build-time only (never shipped to device or the backend), so blast radius
  is the developer's build host, not production.
- **Recommendation:** pin exact versions or add a lockfile (`pip freeze` /
  `requirements.lock`) for the build tool. Gate-2 consideration.

### [INFO] CWE-23 — `matchId` interpolated into local file paths

- **Files:** `PostProcessingViewModel` → `LocalVideoStore.videoURL(for:)` (`videos/{matchId}.mov`),
  `CalibrationStore.load(for:)` (`calibrations/{matchId}.json`); `MatchSummaryView.evaluateCanAnalyse`.
- **Analysis:** `matchId` originates from a server-issued UUID (Phase-1 backend),
  constrained to `[0-9a-f-]`, which cannot contain `/` or `..`, so `appendingPathComponent`
  cannot escape the sandboxed `Documents/{videos,calibrations}/`. Phase 3 adds no new
  untrusted source for this value — consistent with the Phase-2 INFO classification, not
  exploitable.
- **Note for Gate 2:** if a future slice ever sources a match identifier from user input
  or an untrusted response, add UUID-shape validation at the store boundary.

### [INFO] `Documents/` files included in iCloud/device backups

- **Analysis:** The `.mov` and calibration JSON are written under the app-private
  `Documents/` sandbox (verified — no network egress; see §Privacy). By iOS default,
  `Documents/` replicates to the owner's iCloud/Finder backup. "Never leaves the device"
  is precise for **network egress** but not strictly for the owner's own backups.
- **Note for Gate 2:** set `URLResourceValues.isExcludedFromBackup` on those dirs if
  strict on-device-only is required. Carried forward from Phase 2; not a Phase-3
  regression. Low/none risk for a single-user personal app.

### [INFO] Test-fixture token literal in test file

- **File:** `ios/TennisCore/Tests/TennisCoreTests/PostProcessingViewModelTests.swift:55` —
  `private let token = "vm-test-token"`
- **Analysis:** A non-secret, obviously-fake string used to seed a stubbed `MatchClient`
  in unit tests. Confirmed **not** present in any production (non-`Tests/`) source. Not a
  leaked credential.

## Scan results

- **Secrets (all committed changed files):** Clean — no hardcoded api-key/secret/password/
  token/credential literals in production source (`convert_models.py`, `README.md`,
  `requirements.txt`, all Swift). Only the fake test token above.
- **Drive IDs (README §2):** The two IDs (`1XEYZ4myUN7QT-NeBYJI0xteLsvs-ZAOl`,
  `1Eo5HDnAQE8y_FbOftKZ8pjiojwuy2BmJ`) are **public `gdown` file identifiers for public
  model weights**, not credentials — no auth token, cookie, or API key accompanies them.
  Not a secret.
- **Committed model weights:** Clean — `git log --all --diff-filter=A` finds **no**
  `.pt/.cbm/.mlmodel/.mlpackage/.mlmodelc/.onnx/.pth` binary ever added; nothing tracked
  under `cv/models/` or `Resources/ML/`. Both dirs are gitignored and `git check-ignore`
  confirms the ignore is effective. No 40MB blob in history.
- **Dependencies (Swift):** `Package.swift` unchanged — no new third-party Swift
  dependency (AC29). Python deps: see Finding #2.
- **Logging of sensitive data:** Clean — no `print`/`os_log`/`NSLog`/`Logger`/`dump` in
  any changed Swift file. `convert_models.py` prints only model tensor I/O specs and local
  paths to stdout (build tool) — no tokens/user data.
- **Network egress:** Clean — no `URLSession`/`URLRequest`/`dataTask`/`http(s)` in any
  changed Swift file. The only submission path is `matchClient.addShots` (existing
  authenticated route). The `.mov` and homography never leave the device (spec §9 CONFIRMED).
- **Force-unwrap / `try!`:** Clean — none in changed Swift. Model load fails safe:
  `MatchSummaryView.startAnalysis` uses `do/try/catch` → `modelLoadError` alert (verified
  no `try!`); `BallTrackerInference`/`BounceDetectorInference` `init` are throwing and
  surface as a user-visible "Model Not Installed" alert, not a crash.
- **Python `eval`/`exec`/`pickle`:** Clean — the only match, `model.eval()`, is
  torch inference-mode, not Python `eval()`. (The pickle-adjacent `torch.load` is Finding #1.)

## Input validation — submitted zone (client not a new injection vector)

`source:'cv'` shots reuse the existing `addShots`. The `zone` field is produced by
`ZoneClassifier.classify`, a **total function returning exactly one of the six §3.1 enum
strings** (`front_court_left/right`, `baseline_left/right`, `out_left/right`); it clamps
its input into the court rect, so even a degenerate homography (NaN/out-of-range court
coords) still maps to a valid enum value. `PostProcessingViewModel.submit` hard-codes
`source: "cv"` on every element. The client cannot emit a free-form or arbitrary zone.
The backend remains the authority.

## Verdict

**PASS.** No CRITICAL or HIGH findings — does not route back to the coder. Secrets,
committed-weight, dependency (no new Swift dep), on-device file-handling, model-load
fail-safe, privacy/egress, logging, and zone-input-validation checks all pass and match
spec §9. One LOW (`torch.load weights_only`, a near-free build-tool hardening) and four
INFO items (dependency pinning, UUID path boundary, backup exclusion, test-token literal)
are documented for Gate-2 consideration and do not block the PR.

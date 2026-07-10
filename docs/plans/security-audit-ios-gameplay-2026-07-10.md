# Security Audit: iOS Gameplay Screens (Phase 1, Slice 4)

**Date:** 2026-07-10
**Auditor:** security-auditor (AI)
**Branch:** `feat/ios-gameplay` (based on `feat/ios-auth-shell`, not `main` — main has no iOS code; see spec §2b)
**Scope:** `git diff feat/ios-auth-shell..feat/ios-gameplay` — the NEW client-side gameplay work only.
New: `MatchModels`, `ZoneClassifier`, `MatchClient`, `RequestExecutor` (extracted from `APIClient`), the 3 ViewModels
(`MatchListViewModel`, `RecordSessionViewModel`, `MatchSummaryViewModel`), the 4 SwiftUI views + wiring.
Modified (refactor surface): `APIClient.swift`, `RootView.swift`, `TennisShotTrackerApp.swift`, `TabShellView.swift`.
The auth-shell foundation (Keychain/session/token/transport) is pre-existing (audited 2026-07-09) and was
checked only for refactor regressions.
**Verdict:** **PASS** — no CRITICAL or HIGH findings. No coder fix cycle triggered. Two INFO items documented for Gate 2.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 0 |
| MEDIUM   | 0 |
| LOW      | 0 |
| INFO     | 2 |

This is a client-side gameplay slice with no new at-rest data, no new transport, and no new dependency.
Token handling, path construction, JSON parsing, secrets, and logging posture are all sound. The two INFO
items are consistency/robustness notes, not exploitable exposures.

---

## Positive confirmations (the task's explicit asks)

1. **Bearer header scope unchanged by the refactor.** The `RequestExecutor` extraction is a verified 1:1 lift of the
   former `APIClient` private helpers (`git diff feat/ios-auth-shell..feat/ios-gameplay -- .../APIClient.swift`).
   The `Authorization: Bearer <token>` header is attached in exactly one place — `RequestExecutor.authorizedRequest`
   (`RequestExecutor.swift:47-58`) — which throws `.noToken` before any network call if the store is empty.
   - `APIClient.signup` / `APIClient.login` call `executor.buildRequest` (no Bearer) — unauthenticated, correct.
   - `APIClient.fetchMe` calls `executor.authorizedRequest` (Bearer) — unchanged from pre-refactor.
   - All seven `MatchClient` methods call `executor.authorizedRequest` (Bearer) — the 7 gameplay routes.
   The refactor did NOT broaden who receives the Bearer header. Total authorized surface = 7 gameplay routes + `fetchMe`.

2. **Token is never logged, never in a URL/query string, never in an error surfaced to the UI.**
   - No `print` / `debugPrint` / `NSLog` / `os_log` / `Logger` anywhere in the new sources or app target (grep clean).
   - The token lives only in the `Authorization` request header (`RequestExecutor.swift:56`), never in the path or query.
   - `APIError.backendMessage` returns `nil` for `.transport` and `.noToken`, so the raw `URLError` (which never
     contains the token) is the only thing that could reach a view via the fallback — see INFO-1.

3. **Token sent only over the configured base URL.** Every request is built from `config.baseURL.appendingPathComponent(path)`
   (`RequestExecutor.swift:35`). `APIConfig` owns the single `http://localhost:8080` default (`APIConfig.swift:16`); the
   base URL is compile/config-controlled, never user input, so the token cannot be sent to an attacker-chosen host.

4. **No injection / unsafe parsing.** All server responses are decoded with `JSONDecoder().decode(...)` into typed
   Codable DTOs (`MatchModels.swift`). No `eval`, `NSExpression`, or dynamic code path exists (grep clean).

5. **Zone strings are constrained to the six-value enum end-to-end.** `ZoneClassifier.classify` returns only the six
   string literals (`ZoneClassifier.swift:26-32`) — total and deterministic, with a degenerate-rect fallback of
   `front_court_left` and out-of-rect clamping. `RecordSessionView` feeds `ZoneClassifier.classify(...)` output
   (`RecordSessionView.swift:96`) directly into `viewModel.record(zone:)` (`:40`) — no free-form string reaches the client.
   The backend remains the authority and validates the value regardless.

6. **No secrets committed.** Non-test secrets grep clean; no hardcoded tokens/keys/URLs beyond the intended
   `localhost` seam. No private keys. The only `.env*` tracked is `.env.example` (placeholders `CHANGE_ME_*`), and it
   is NOT part of this slice's diff.

7. **No new third-party dependency.** `Package.swift` declares `dependencies: []` — only Apple frameworks
   (`Foundation`, `CoreGraphics`, `Observation`). No supply-chain surface added by this slice.

---

## Findings

### [INFO] CWE-209 — `error.localizedDescription` reaches the UI on transport/`.noToken` errors
- **Files:** `MatchListViewModel.swift:76-81`, `RecordSessionViewModel.swift:119-124`,
  `MatchSummaryViewModel.swift:50-55` (the shared `errorMessage(_:)` helper), surfaced by
  `RecordSessionView.swift:51` (`Text(error)`), `MatchSummaryView.swift:21` (`ContentUnavailableView(error, ...)`),
  `MatchListView.swift:26`, `CreateMatchSheet.swift:28`.
- **Detail:** When `APIError.backendMessage` is `nil` (i.e. `.transport` or `.noToken`), the three VMs fall back to
  `error.localizedDescription`, which is then displayed verbatim. For a `.transport` error this is the wrapped
  `URLError`'s description (e.g. "Could not connect to the server"). This differs from `AuthView.swift:89`, which
  uses a generic "Something went wrong. Please try again." fallback for the same case.
- **Why INFO, not higher:** The bearer token is carried in the `Authorization` header and is NEVER present in a
  `URLError`, so it cannot leak this way. A `URLError.localizedDescription` is a generic sentence, not a stack trace
  or raw response body; any host string it could carry is the compile-controlled `localhost` base URL. Single-user,
  low-sensitivity app. This is a UX/consistency divergence from the established `AuthView` posture, not exploitable
  data exposure.
- **Remediation (optional, Gate-2 decision):** for parity with `AuthView`, map the nil-`backendMessage` case to a
  generic user-facing string in the shared VM helper. No behavior change beyond the displayed text.

### [INFO] CWE-23 — Server-issued match `id` is string-interpolated into the request path
- **File:** `MatchClient.swift:51, 62, 76, 88, 99` (`"/matches/\(id)"`, `"/matches/\(matchID)/…"`).
- **Detail:** The `{id}` path segment is built by Swift string interpolation before
  `config.baseURL.appendingPathComponent(path)`. If the server ever returned an `id` containing path metacharacters
  (`../`, `?`, `#`), the constructed path could in principle be altered.
- **Why INFO, not higher:** The `id` originates exclusively from a server-issued `MatchResponse.id` (a UUID) —
  it is never user-typed. It reaches `MatchClient` only via `.session(match.id)` / `.summary(match.id)` /
  `createdMatch.id` / `endedMatch.id` routing (`MatchListView.swift:34-35`, `TabShellView.swift`,
  `RecordSessionView.swift:61`). `appendingPathComponent` also percent-encodes stray characters. There is no
  realistic attacker-controlled path here in a single-user app talking to its own backend.
- **Remediation (optional, defense-in-depth): ** percent-encode the id with a path-segment-allowed character set
  before interpolation, or assert it is a well-formed UUID. Not required for this slice.

---

## Checklist results

**1. Token handling — PASS.** Not logged, not in URL/query, not in UI errors (token absent from `URLError`), sent only
over `config.baseURL`. See positive confirmations 1–3 and INFO-1.

**2. RequestExecutor refactor — PASS (no regression).** Verified 1:1 lift; Bearer attached only in `authorizedRequest`
(7 gameplay routes + `fetchMe`), never signup/login. The old `private EmptyBody` became `internal EmptyBody` in
`RequestExecutor.swift:14` — a documented, minimal visibility widening required so sibling `MatchClient` GET methods
can pass `nil as EmptyBody?`; it exposes an empty struct, not any data.

**3. Injection / unsafe parsing — PASS.** JSON decode only, no eval. Path `{id}` is server-origin (INFO-2).

**4. Data exposure / logging — PASS.** No `print`/`os_log`/`Logger`; no match/shot payload or PII/token written to logs.

**5. Secrets — PASS.** No hardcoded secrets/keys/URLs (only the intended `localhost` seam); no private keys; no `.env`
in this slice's diff.

**6. Zone strings / user taps — PASS.** Client emits only the six fixed literals; classifier is total; backend validates.

**7. Dependencies — PASS.** No new third-party SPM dependency (`dependencies: []`).

**Auth-shell regression sweep — PASS.** The other modified files (`RootView.swift`, `TennisShotTrackerApp.swift`,
`TabShellView.swift`) are wiring/routing changes only. No touch to `KeychainTokenStore`, `SessionStore`, or
`Info.plist`/ATS in this slice; the 2026-07-09 auth-shell findings (Keychain `OSStatus` discard, ATS scoping) are
unchanged and out of this slice.

---

## Dependency Audit
- **Swift/SPM (`ios/TennisCore/Package.swift`):** `dependencies: []` — only Apple frameworks. No supply-chain surface.
- Go / Python: out of scope (client-side iOS slice). The deferred MEDIUM body-size finding on the backend gameplay
  branch is server-side and not part of this iOS slice.

---

## Verdict

**PASS.** Zero CRITICAL / HIGH / MEDIUM / LOW findings. The `RequestExecutor` refactor is a clean 1:1 extraction that
does not broaden the Bearer-header surface; the token is never logged, never in a URL, and never leaked into a
UI-surfaced error (it is absent from the only fallback path, `URLError`). Match ids in paths are server-issued UUIDs,
zone strings are fixed to the six-value enum end-to-end, no secrets are committed, and no third-party dependency is
added. The two INFO items (generic-vs-specific transport-error text for `AuthView` parity; defense-in-depth
percent-encoding of the server-issued id) are documented for the Gate-2 human decision and do not trigger the coder
fix cycle.

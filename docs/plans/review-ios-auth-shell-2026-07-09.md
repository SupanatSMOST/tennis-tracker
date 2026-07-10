# Code Review: iOS Auth + 3-Tab Shell (Phase 1, Slice 2)

**Date:** 2026-07-09
**Reviewer:** reviewer (AI)
**Branch:** `feat/ios-auth-shell`
**Scope:** `git diff main...feat/ios-auth-shell -- ios/` (TennisCore package + TennisShotTracker app target)
**Verdict:** PASS (APPROVED WITH NITS) — no BLOCKERs; SHOULD-FIX items are non-blocking and may ship as follow-ups.

---

## Test-gate status (confirmed)

- `swift test` in `ios/TennisCore`: **52 tests, 0 failures** (re-run confirmed green).
- `xcodebuild build` app-target gate: **BLOCKED by environment** (simulator SDK only, no iOS platform for destination). Per task instructions, not run; AC20 not independently confirmable here. AC21/AC22/AC23 reviewed by inspection.

---

## Spec Compliance

### TennisCore — models & decoding
- [x] AC1: `SignupResponse.userId: String` via CodingKeys (`user_id`), tested incl. non-UUID regression — ✅ implemented & tested
- [x] AC2: `LoginResponse.token` — ✅ implemented & tested
- [x] AC3: `MeResponse.userId: String` via CodingKeys, tested incl. non-UUID — ✅
- [x] AC4: `ErrorResponse.error` — ✅ implemented & tested

### TennisCore — APIClient behavior
- [x] AC5: 201 signup → `persistToken` via injected store, tested — ✅
- [x] AC6: 200 login → same `persistToken` path; shared-path test present — ✅
- [x] AC7: 401 → `.invalidCredentials(msg)`, backend message surfaced, tested — ✅
- [x] AC8: 409 → `.usernameTaken(msg)`, tested — ✅
- [x] AC9: 400 → `.validation(msg)`, tested — ✅
- [x] AC10: `fetchMe` sends `Authorization: Bearer <token>`, tested via captured request — ✅
- [x] AC11: All tests use `StubTransport` + `InMemoryTokenStore`; `URLSession` only in `URLSessionTransport` (never in tests) — ✅

### TennisCore — Keychain wrapper
- [x] AC12: store→read→clear round-trip tested against `InMemoryTokenStore` (real `SecItem` deferred per A-8, correctly documented) — ✅

### TennisCore — session/routing state machine
- [x] AC13: no token → `.unauthenticated`, tested — ✅
- [x] AC14: token + 200 → `.authenticated(me: resolved)`, tested — ✅
- [x] AC15: token + 401 → clear + `.unauthenticated`, tested — ✅
- [x] AC16: token + transport error → retain + `.authenticated(me: nil)`, tested — ✅
- [x] AC17: signup/login → `.authenticated`; rethrow-on-4xx guard tested — ✅
- [x] AC18: logout → clear + `.unauthenticated`, tested — ✅
- [x] AC19: base URL only in `APIConfig` seam; `APIClient` reads `config.baseURL`, no literal; injected-config test asserts scheme/host/port — ✅

### App target — build only / inspection
- [~] AC20: `xcodebuild build` — not run (environment-blocked per task); relying on Task 8 prior proof
- [x] AC21: `XCLocalSwiftPackageReference "../TennisCore"` + `XCSwiftPackageProductDependency` (productName `TennisCore`) linked into app target — ✅ by inspection of pbxproj
- [x] AC22: no networking/token/Keychain/model/validation logic in app target — every such call is a method on a TennisCore type. Views hold only `@State` UI state (form fields, submit flag, error string). `Security` imported only in `KeychainTokenStore` — ✅ by inspection
- [x] AC23: `RootView` routes `.resolving`→ProgressView, `.unauthenticated`→AuthView, `.authenticated`→TabShellView; `ProfileView` Logout calls `sessionStore.logout()` — ✅ by inspection

### Gate-1 decisions (constraints)
- [x] Base URL: default `http://localhost:8080` lives only in `APIConfig.init` default; single injectable seam; no other literal in networking logic — ✅
- [x] Password validation MIRRORED client-side (`PasswordValidator`: ≥8 chars / ≤72 bytes, byte-check first) AND backend `{"error"}` still surfaced on 400 via `APIError.validation` — ✅ (byte-vs-char distinction tested with 🎾 and ZWJ-family fixtures)
- [x] Keychain accessibility: `kSecAttrAccessibleAfterFirstUnlock` — ✅ (NOT a `...ThisDeviceOnly` variant)
- [x] Launch offline behavior: OPTIMISTIC (token retained + enter shell) — ✅
- [x] `user_id` → Swift `String`, never `UUID` — ✅

---

## Rulings on the two flagged design questions

### Item 3 — `SessionStore.resolve()` catch-all optimism: **ACCEPT as-is**

`resolve()` clears the token only on `APIError.invalidCredentials` (401) and retains it via a catch-all on every other error — so a launch-time HTTP 500 or a JSON decode failure ALSO drops the user optimistically into `.authenticated(me: nil)`, not just `.transport`.

**Ruling: ACCEPT. No change required.** The discriminating constraint is the spec's own security rule (§7): *"A valid token is discarded only on an explicit GET /me 401 (server-side rejection) or on logout — never on a transient transport error … The client MUST NOT invent client-side expiry."* Under that rule, no non-401 outcome gives the client grounds to distrust the token:
- A **500** is a server fault — it says nothing about token validity.
- A **decode failure** is contract drift — it also does not prove the token invalid.

Narrowing the retain branch to only `.transport` (letting 500/decode fall through to `.unauthenticated`) would actively **violate** the never-expire model by logging out a user who holds a perfectly valid token whenever the server hiccups or the contract drifts. Retain-and-enter is therefore the *faithful* implementation of Gate-1 OQ-4 + §7, not a risky broadening. The single-user, session-never-expires model and the fact that the shell already tolerates `me: nil` (the login path produces exactly that state) make "enter the shell" the correct target state. A distinct error/retry state would be out of scope this slice.

Associated NIT: plan §2.1/§5 describe the branch as keying off `APIError.transport`; the code uses a broader catch-all (its doc comment says "any other error"). The code is the better choice for the reason above — treat this as an intentional, spec-consistent broadening. See NIT-1.

### Item 4 — Keychain silent write (`OSStatus` discarded): **ACCEPT for this slice**

`KeychainTokenStore` conforms to a non-throwing `TokenStore` protocol and discards the `OSStatus` from `SecItemAdd`/`SecItemUpdate`/`SecItemDelete`.

**Ruling: ACCEPT for this slice. Not a blocker.** Justification: the real `SecItem` path is explicitly deferred to a device/simulator test (A-8) and is not exercised by `swift test`; the non-throwing protocol is a deliberate seam design; and the failure mode is benign for a single-user app (a failed `set()` merely logs the user out on next launch — no leaked-token or auth-bypass hole). See SHOULD-FIX-1 for the follow-up to attach before the device path is exercised.

---

## Findings

### [SHOULD-FIX-1] `KeychainTokenStore.swift:42-76` and `SessionStore.swift:82-88` — silently discarded errors
- **Risk (Keychain):** `set()` and `clear()` ignore their `OSStatus`. The security-relevant direction is `clear()` in the **logout** path — if `SecItemDelete` fails, the token *survives* and logout does not actually purge it. A failed `set()` silently logs the user out next launch. Both are invisible today.
- **Risk (resolve catch-all):** the non-401 branch discards the 500/decode error entirely with no log, so persistent 500s or contract drift are undiagnosable in the field.
- **Fix (defer to when the device path lands / cheap to add now):** capture `OSStatus` in `KeychainTokenStore` and log (`os.Logger`) or `assertionFailure` on non-`errSecSuccess` (and non-`errSecItemNotFound` for delete). In `resolve()`, log the caught non-401 error before entering the optimistic branch. This keeps optimism intact (no behavior change) while removing the silent-swallow. Left for the coder — it is an additive behavior change, not a trivial formatting fix.

### [NIT-1] Plan/code divergence — `resolve()` branch description
- **Suggestion:** Plan §2.1/§5 say the offline branch keys off `APIError.transport`; the code uses a catch-all (correctly — see Item 3 ruling). Update the plan text to describe the catch-all as intentional so the docs match the code. Doc-only.

### [NIT-2] `APIClient.swift:97` — `appendingPathComponent` is soft-deprecated
- **Suggestion:** `URL.appendingPathComponent(_:)` is deprecated in favor of `appending(path:)` on newer SDKs. Behavior is correct here (verified: leading-slash paths like `/auth/signup` are not double-encoded against a `host:port` base). Non-blocking; migrate opportunistically.

---

## Auto-fixes Applied
None. The code is clean (no formatting, import, or obvious-oversight issues to fix). The one force-unwrap (`APIConfig.swift:16`) is intentional on a compile-time-valid literal and carries a `ponytail:` acknowledgement — acceptable.

---

## Summary

**PASS (APPROVED WITH NITS).** All 23 ACs and all five Gate-1 constraints are honored; the 19 logic ACs are proven by a green 52-test `swift test` run, and AC21/AC22/AC23 hold by inspection (AC20's `xcodebuild build` gate is environment-blocked and relies on the prior Task-8 proof). Item 3: the `resolve()` catch-all is **ACCEPTED as-is** — retaining the token on 500/decode failures is the faithful reading of the spec's never-expire rule (§7); narrowing to `.transport` only would wrongly lock out valid sessions. Item 4: the silent Keychain write is **ACCEPTED for this slice** (real `SecItem` deferred per A-8, benign failure mode), with a SHOULD-FIX to surface `OSStatus`/errors — notably the logout `clear()` path — before the on-device Keychain test lands. No BLOCKER or coder-rework items; the two SHOULD-FIX/NIT items are safe follow-ups.

# Security Audit: iOS Auth + 3-Tab Shell (Phase 1, Slice 2)

**Date:** 2026-07-09
**Auditor:** security-auditor (AI)
**Branch:** `feat/ios-auth-shell`
**Scope:** `git diff main...feat/ios-auth-shell -- ios/` — `ios/TennisCore/` (auth/session/token/networking) + `ios/TennisShotTracker/` (SwiftUI shell)
**Verdict:** PASS WITH NOTES — no CRITICAL or HIGH findings. No coder fix cycle triggered.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 0 |
| MEDIUM   | 1 |
| LOW      | 0 |
| INFO     | 2 |

This is a client-side auth slice. The token-at-rest, in-transit, secrets, transport, and error-leakage posture are all sound. The single security-relevant behavior gap is the logout `clear()` swallowing its `OSStatus` (item 5), rated **MEDIUM** — it does not block this slice.

---

## Findings

### [MEDIUM] CWE-613 — Incomplete session termination on logout (`OSStatus` discarded)
- **File:** `ios/TennisCore/Sources/TennisCore/Auth/KeychainTokenStore.swift:69-76` (`clear()`); same pattern in `set()` :42-67.
- **Code:** `_ = SecItemDelete(query as CFDictionary)` — the `OSStatus` return is discarded.
- **Risk:** If `SecItemDelete` fails on the logout path (`SessionStore.logout()` → `tokenStore.clear()`), the bearer JWT **survives in the Keychain** while in-memory state still transitions to `.unauthenticated`. On the next launch, `resolve()` reads the surviving token and re-enters the shell — logout did not actually purge the credential. The failure is invisible (no log, no assert).
- **Why this is MEDIUM, not HIGH/CRITICAL** (threat-model based, not deferral-based):
  - It is **not** a token leak and **not** an auth bypass — no attacker gains access they did not already have; it is *incomplete termination* of the current user's own session.
  - In-memory `state` correctly goes `.unauthenticated`, so the UI does return to the auth screen within the running session.
  - Single-user app, low-sensitivity data (tennis shot tracking), and `SecItemDelete` failure on a healthy device with `kSecAttrAccessibleAfterFirstUnlock` accessibility is a near-zero event.
  - A defensible case for LOW exists on the same reasoning. Under **either** rating this does **not** meet the CRITICAL/HIGH bar and does not trigger the coder fix cycle.
- **Remediation (cheap, additive, recommended before the on-device Keychain test lands):** capture the `OSStatus` in `clear()` and `set()`; on non-`errSecSuccess` (and, for delete, non-`errSecItemNotFound`) log via `os.Logger` or `assertionFailure`. This surfaces the failure without changing the optimistic behavior. Consistent with reviewer SHOULD-FIX-1.

### [INFO] Inaccurate comment — claimed iCloud Keychain sync does not occur
- **File:** `ios/TennisCore/Sources/TennisCore/Auth/KeychainTokenStore.swift:9`
- **Detail:** The comment states the item "participates in iCloud Keychain sync." It does not — `kSecAttrSynchronizable` is never set, so the item stays device-local. Not-syncing is the safer posture (the token does not propagate to other devices), so this is a comment-accuracy note only, not a security finding.
- **Remediation:** correct the comment to say the item is device-local (not synced). No behavior change.

### [INFO] `resolve()` non-401 branch swallows the underlying error with no log
- **File:** `ios/TennisCore/Sources/TennisCore/Session/SessionStore.swift:82-88`
- **Detail:** The catch-all optimistic branch discards the caught error (500 / decode / transport) entirely. This is the *correct* security behavior (a non-401 does not prove the token invalid — spec §7 never-expire rule), so retain-and-enter is right. The only gap is diagnosability: persistent 500s or contract drift are undetectable in the field. No sensitive data is exposed by adding a log here (the error is a `URLError`/decode error, not a credential).
- **Remediation:** log the caught non-401 error before entering the optimistic branch. Diagnostics only; no behavior change.

---

## Checklist results (task items 1-6)

**1. Token at rest — PASS.** JWT is stored ONLY via `KeychainTokenStore` (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`). `grep UserDefaults` across `ios/` → clean. No plist/plaintext token write. Accessibility attribute is appropriate: `AfterFirstUnlock` allows post-boot background access without exposing the item before first unlock; it is NOT the insecure `kSecAttrAccessibleAlways`.

**2. Token in transit / logging — PASS.** No `print`/`debugPrint`/`NSLog`/`os_log`/`Logger` calls anywhere in `ios/TennisCore/Sources` or the app target — credentials and tokens are never logged. The `Authorization: Bearer <token>` header is set only in `APIClient.fetchMe` (`APIClient.swift:63`) against `config.baseURL`-derived requests; the base URL is config/compile-controlled, never user input, so the token cannot be sent to an arbitrary host.

**3. Secrets in code — PASS.** No hard-coded credentials, tokens, or API secrets. The only URL literal is the `http://localhost:8080` default in `APIConfig.init` (`APIConfig.swift:16`), which is the intended single seam. The secrets grep only matched `password: "password1"` in test fixtures (`*Tests.swift`) — test data, not real secrets. No `.env` tracked (`git ls-files ios/ | grep .env` → clean). No private keys.

**4. Transport security — PASS.** The ATS exception in `Info.plist` is correctly SCOPED: `NSAppTransportSecurity` → `NSExceptionDomains` → `localhost` → `NSExceptionAllowsInsecureHTTPLoads=true`. There is NO blanket `NSAllowsArbitraryLoads` (grep confirmed absent). Insecure HTTP is permitted only to `localhost`; any production VPS URL must be https (enforced by default ATS for non-excepted domains).

**5. Logout completeness — MEDIUM (see finding above).** Silent `OSStatus` discard in `clear()` = CWE-613 incomplete session termination. Not a leak or bypass; benign single-user failure mode; near-zero probability. **Does not trigger the fix cycle under any defensible rating.**

**6. Error-message leakage — PASS.** `APIClient.mapError` (`APIClient.swift:110-119`) surfaces only the controlled backend `{"error"}` string or a generic `"HTTP <status>"` fallback — never raw response bytes or a stack trace. For `.transport`, `APIError.backendMessage` returns `nil`, so `AuthView.submit()` (`AuthView.swift:89`) falls back to a generic `"Something went wrong."` — the underlying `URLError` (which can carry host/path detail) never reaches the UI.

---

## Dependency Audit
- **Swift/SPM (`ios/TennisCore/Package.swift`):** no third-party dependencies declared — only Apple frameworks (`Foundation`, `Security`, `Observation`, `SwiftUI`). No external supply-chain surface to audit for this slice.
- Go / Python: out of scope (this is an iOS client slice).

---

## Verdict

**PASS WITH NOTES.** Zero CRITICAL/HIGH findings; token-at-rest (Keychain, `AfterFirstUnlock`), in-transit (Bearer only to config host, no credential logging), secrets, scoped-localhost ATS, and error-leakage posture are all sound. The one MEDIUM (logout `clear()` swallowing `OSStatus`, CWE-613) is a benign, near-zero-probability incomplete-session-termination gap in a single-user app and does not block this slice — record it with the two INFO items as follow-ups.

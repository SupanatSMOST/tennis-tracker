# Security Audit: Backend + Auth Foundation (Phase 1, Slice 1)

**Date:** 2026-07-09
**Auditor:** security-auditor (AI)
**Scope:** `tennis/backend/` changes in `ea88168..HEAD` (25 feat/test commits, 28 files).
Diffed against the slice base `ea88168`, NOT `main` (unrelated git history — would show phantom cross-history noise).
**Verdict:** **PASS** — no CRITICAL or HIGH findings. Cleared for deploy.

---

## Summary

The auth foundation is well-built and closely tracks the Gate-1 spec §7. Password
storage (bcrypt cost 12, >72-byte rejection, <8-rune minimum), JWT handling
(HS256-only with a double alg guard), parameterized SQL, and secret handling are all
correct. No secrets or plaintext credentials are committed or logged. `PasswordHash`
carries no JSON tag and cannot leak to the wire.

All findings below are LOW/INFO for the app's stated single-user personal-app context
and do NOT block deploy. Per the pipeline rule, nothing returns to the coder as a
blocking fix. Recommendations are documented for the multi-user/public future the spec
itself flags ("revisit if the app goes multi-user or public").

---

## Findings

### [LOW] CWE-208 — Login user-enumeration timing side-channel
- **File:** `backend/internal/service/auth_service.go:93-104` (`Login`)
- **Observed:** An unknown username returns `ErrInvalidCredentials` immediately (the
  `GetUserByUsername` → `ErrUserNotFound` branch, no bcrypt call). A known username
  with a wrong password runs `bcrypt.CompareHashAndPassword` at cost 12 (tens of ms)
  before returning the identical error. The response *body* is correctly
  indistinguishable (AC16 as written is met for the code-path/response oracle), but the
  response *time* differs measurably: fast = no such user, slow = user exists.
- **Risk:** Account-existence enumeration via timing. This partially defeats AC16's
  stated intent ("callers cannot infer account existence"). The `auth_service.go`
  comment claims full AC16 compliance; strictly, only the response-body oracle is closed.
- **Severity rationale:** For a single-user personal app there is exactly one account to
  enumerate, so the practical value is near-zero → LOW, non-blocking. Rises to **MEDIUM**
  if the app goes multi-user or public (per the spec's own revisit caveat).
- **Recommendation (defer):** When the user isn't found, still run
  `bcrypt.CompareHashAndPassword` against a fixed dummy bcrypt hash to equalize timing,
  then return `ErrInvalidCredentials`. Do not build this now for single-user; flag it in
  the multi-user slice.

### [INFO] CWE-521 — No strength floor on `JWT_SIGNING_KEY`
- **File:** `backend/internal/config/config.go:24-27`
- **Observed:** `Load` only checks that `JWT_SIGNING_KEY` is non-empty. A 1-byte key is
  accepted.
- **Risk:** With HS256 and non-expiring tokens, key secrecy and strength are the entire
  security boundary — a weak key makes every token forgeable, and tokens cannot be
  revoked. There is no lower bound enforced.
- **Recommendation (defer):** Enforce a minimum length (e.g. `>= 32` bytes) at load and
  fail boot otherwise. Cheap hardening; aligns with the non-expiring-token trade-off
  where key strength is load-bearing.

### [INFO] CWE-770 — No request-body size limit on auth endpoints
- **File:** `backend/internal/handler/auth.go:62,103` (`json.NewDecoder(r.Body)`)
- **Observed:** Signup/login decode the request body with no `http.MaxBytesReader` cap.
- **Risk:** Unbounded body → memory-exhaustion DoS vector.
- **Recommendation (defer):** Wrap with `http.MaxBytesReader(w, r.Body, 1<<20)` (or
  similar) before decoding. INFO for single-user, trusted-client context.

### [INFO] — `.env` not covered by `.gitignore`
- **File:** `backend/.gitignore` (only ignores `/server`)
- **Observed:** No `.env` pattern is ignored. No `.env` is currently committed or present
  locally (verified: `git ls-files` clean, `find` returns none), so this is a
  future-footgun, not a live exposure.
- **Recommendation (defer):** Add `.env` and `*.env` to `backend/.gitignore` to prevent
  an accidental future commit of `DATABASE_URL` / `JWT_SIGNING_KEY`.

---

## Threat areas — cleared

- **Password storage (A02):** bcrypt cost 12 (`auth_service.go:65`). Validation runs
  *before* bcrypt so the >72-byte rejection prevents silent truncation weakening long
  passwords (`:60-62`); <8-rune minimum enforced (`:57`). Plaintext never persisted
  (only the hash is stored, `user_store.go:36`) and never logged (grep clean).
- **JWT (A02/A07):** HS256 only. `Parse` (`token_service.go:37-51`) applies BOTH
  `jwt.WithValidMethods([]string{"HS256"})` AND an HMAC method type assertion in the
  keyfunc — this correctly blocks `alg:none` (method is `signingMethodNone`, not HMAC)
  and RS256/algorithm-confusion. `sub` = user UUID, validated via `uuid.Parse`. No `exp`
  by design (matches spec/DESIGN.md). Signing key sourced only from `JWT_SIGNING_KEY`
  env; never hardcoded, never logged.
- **Non-expiring token trade-off:** Correctly implemented and no worse than documented.
  Tokens deliberately carry no `exp` and there is no revocation machinery — exactly the
  documented single-user trade-off. The one residual risk this creates (key strength is
  now the whole ballgame) is captured as the `JWT_SIGNING_KEY` INFO above.
- **Auth flows:** Login returns identical `ErrInvalidCredentials` for unknown-user and
  wrong-password (response oracle closed; timing oracle noted as LOW above). Signup
  duplicate surfaces as a clean 409 "username already taken" with no leak
  (`auth.go:76-77`). Middleware (`middleware.go`) rejects missing/malformed/
  bad-signature tokens (401), unknown/deleted subjects (401, AC20), and correctly
  returns **500** — not 401 — on unexpected DB error (`:66-69`), logging the error
  server-side only.
- **Injection (A03):** All production SQL uses pgx positional parameters
  (`user_store.go` INSERT/SELECT with `$1..$3`). No string-built SQL. The one
  `fmt.Sprintf` with SQL is in `user_store_test.go:60` — test-only table-name
  interpolation, not user input.
- **Secret handling:** No secrets in committed code (grep clean). No `.env` committed.
  Signing key and passwords never appear in slog output (grep clean); `main.go` logs
  only `err` values from config/pool/server, none of which carry the key.
- **Info disclosure (A05):** Error responses return fixed generic strings
  ("internal server error", "unauthorized", "invalid credentials") via
  `writeError`/`writeJSON` (`respond.go`, `auth.go`). No stack traces, DB errors, or
  internal detail reach clients. Internal errors are logged server-side only.
- **Response DTO leakage:** `model.User.PasswordHash` has no JSON tag
  (`model/user.go:9-15`); client-facing DTOs (`authResponse`, `tokenResponse`,
  `meResponse`) never include the hash. No leakage path.

---

## Dependency Audit

No network install permitted; based on versions in `go.mod`/`go.sum`. No known-vulnerable
versions evident among the audited direct dependencies:

| Dependency | Version | Note |
|---|---|---|
| `github.com/golang-jwt/jwt/v5` | v5.3.1 | Current v5 line; alg-confusion CVEs (e.g. GO-2024-xxxx affecting older v4/pre-5.2.2) do not apply. Guard also enforced in-code. |
| `golang.org/x/crypto` | v0.54.0 | Recent; bcrypt package unaffected by known advisories. |
| `github.com/jackc/pgx/v5` | v5.10.0 | Current; no known advisory. |
| `github.com/google/uuid` | v1.6.0 | Stable; no known advisory. |

Note: `govulncheck ./...` should be run in CI where network is available to confirm
against the live Go vuln DB. This audit reflects a static, version-based assessment only.

---

## Verdict

**PASS.** No CRITICAL or HIGH findings — the slice is cleared for deploy. The four
LOW/INFO items (login timing oracle, JWT key strength floor, request-body size limit,
`.gitignore` `.env` gap) are documented hardening recommendations appropriate to defer;
the timing oracle should be promoted to a blocking fix if/when the app goes multi-user or
public, per the spec's own revisit caveat.

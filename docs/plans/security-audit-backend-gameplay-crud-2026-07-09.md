# Security Audit: Phase 1 Slice 3 — Backend Gameplay CRUD

**Date:** 2026-07-09
**Auditor:** security-auditor (AI)
**Scope:** `git diff main..HEAD -- backend/` (app files only)
**Verdict:** PASS (no Critical/High findings) — 1 Medium, 3 Info, all non-blocking

Files audited: `internal/model/match.go`, `internal/store/match_store.go`,
`internal/store/record_store.go`, `internal/service/gameplay_service.go`,
`internal/handler/gameplay.go`, `internal/handler/router.go`,
`cmd/server/main.go`, `migrations/00003_gameplay_indexes.sql`. Trust anchor
reviewed (not in diff): `internal/handler/middleware.go`,
`internal/service/token_service.go`, `internal/handler/respond.go`.

---

## 1. Broken Object-Level Authorization (IDOR) — PRIMARY RISK — CLEAN

Every one of the 7 routes derives `user_id` exclusively from the JWT context
(`userFromContext` → `AuthedUser.UserID`, injected by `RequireAuth`). No handler
reads a user id from the request body, query string, or path — the only path
param is `{id}` (match id), and ownership is always enforced by a SQL predicate.

Per-route ownership enforcement (SQL predicate, not fetch-then-compare):

| Route | Ownership gate |
|-------|----------------|
| `POST /matches` (CreateMatch) | `user_id` set from JWT into INSERT (`match_store.go:31`) |
| `GET /matches` (ListMatches) | `WHERE user_id = $1` (`match_store.go:42`) |
| `GET /matches/{id}` (GetMatch) | `WHERE match_id = $1 AND user_id = $2` (`match_store.go:74`) |
| `POST /matches/{id}/end` (EndMatch) | `WHERE match_id = $1 AND user_id = $2 FOR UPDATE` (`match_store.go:103`) |
| `POST /matches/{id}/records` (AddRecords) | `WHERE match_id = $1 AND user_id = $2 FOR UPDATE` (`record_store.go:31`) |
| `GET /matches/{id}/records` (ListRecords) | `GetMatchOwned` predicate, then records by match_id (`record_store.go:98`) |
| `GET /matches/{id}/summary` (GetSummary) | `GetMatchOwned` predicate, then summary by match_id (`record_store.go:63`) |

**Two-query pattern in ListRecords / GetSummary — explicitly reviewed and safe.**
These do not use a single joined predicate. They first call `GetMatchOwned`
(`WHERE match_id AND user_id` — the ownership gate is a predicate, satisfying the
"predicate not fetch-then-compare" requirement), then fetch children by
`match_id` alone in a second, non-transactional query. This is not a TOCTOU/IDOR
gap: match→record and match→summary ownership is immutable (a record can never
be reparented to another user's match; `record.match_id` is fixed at insert),
so there is no window in which the second query could return another user's data
for a match the caller was just confirmed to own. No leak.

`EndMatch` step 2 issues `UPDATE ... WHERE match_id = $1` (no `user_id`) — safe
because step 1 already locked the exact owned row with `FOR UPDATE` in the same
transaction; the id is proven-owned and row-locked before the update.

**Result: no IDOR. All access scoped to the JWT-derived user.**

## 2. SQL Injection — CLEAN

Every query in `match_store.go` and `record_store.go` uses pgx positional
parameters (`$1..$n`). No `fmt.Sprintf`, no string concatenation of user input
into SQL anywhere in `internal/store` or `internal/service` (grep confirmed
zero matches). The aggregation/upsert/stale-delete in `RebuildSummary`
(`match_store.go:150-174`) and the batch-insert loop in `InsertRecords`
(`record_store.go:44-53`) are fully parameterized. `zone`, `source`, and
coordinate values flow as bound parameters, never interpolated.

## 3. Auth Bypass — CLEAN

All 7 gameplay routes are registered via
`mux.Handle(..., RequireAuth(tokens, s)(http.HandlerFunc(...)))`
(`router.go:36-42`). None is registered with bare `HandleFunc`. `RequireAuth`
(`middleware.go:37-79`) rejects missing/malformed/invalid/unknown-subject tokens
with 401 *before* `next.ServeHTTP` is ever called — so a 401 always precedes any
data access or 404. Each handler additionally re-checks `userFromContext` and
returns 401 if absent (defensive guard). The token verifier rejects `alg:none`
and RS/HS confusion (`token_service.go:45-50`). No unprotected route.

## 4. Information Disclosure — CLEAN

- **404-not-403 no-leak invariant holds.** Unknown match, not-owned match, and
  unparseable UUID all map to identical `404 {"error":"match not found"}`
  (`gameplay.go:118`, `mapGameplayError` at `:131-132`, `ErrMatchNotFound`
  comment at `match_store.go:13-16`). An attacker cannot distinguish "exists but
  not yours" from "does not exist."
- **No DB error text leaked.** The `default` branch of `mapGameplayError`
  (`gameplay.go:135-138`) logs the real error via `slog.ErrorContext` and returns
  a fixed `500 {"error":"internal server error"}`. Raw `err.Error()` (which could
  carry SQL/driver detail) is never written to the response body.
- **No sensitive data logged.** The only log sink in the diff is the 500 branch,
  which logs the error object — no tokens, passwords, or PII. The signing key is
  never logged (`main.go` logs config errors but not the key).

## 5. Input Validation / Resource Abuse

- Coordinate/timestamp parsing (`court_x`/`court_y` as `*float32`, `ts_ms` as
  `*int32`) is handled by `encoding/json`. Overflow or type mismatch yields a
  decode error → `400 "malformed request body"`; no panic surface. Not a finding.
- `court_surface` validated against `{hard,clay,grass}`; `source` against
  `{cv,manual}`; empty `zone` and empty `shots` batch rejected with 400. All
  validation runs before any store/tx call (`gameplay_service.go:116-128`).
- No pagination on list endpoints — approved OQ baseline, accepted risk, not a
  finding.

## Findings

### [MEDIUM] CWE-770 — Unbounded request body / batch insert (no size limit)
- **File:** `internal/handler/gameplay.go:281-311` (AddRecords), `cmd/server/main.go:53`
- **Vulnerability:** No `http.MaxBytesReader` guard on request bodies and no
  server-level `ReadTimeout`/`WriteTimeout`. `AddRecords` decodes the entire JSON
  body into memory and allocates a `[]service.ShotInput` of arbitrary length
  *before* the ownership check runs (ownership is verified last, inside
  `InsertRecords` → `record_store.go:31`). A single authenticated caller can POST
  a multi-hundred-MB `shots` array — for *any* match id, including one they do
  not own — and force a large allocation on every request before the 404 is
  returned.
- **Exploit scenario:** Authenticated client repeatedly POSTs oversized bodies to
  `/matches/{any-id}/records`, driving memory/CPU pressure. Amplification is
  limited to the caller's own connection (no fan-out), so impact is bounded —
  hence Medium, not High.
- **Remediation (primary):** Wrap request bodies in
  `r.Body = http.MaxBytesReader(w, r.Body, <limit>)` before decoding (e.g. 1 MB),
  and set `ReadTimeout`/`WriteTimeout` on an explicit `http.Server` instead of
  bare `http.ListenAndServe`. **Secondary:** reject `len(shots) > N` in
  `GameplayService.AddRecords` alongside the existing empty-batch check.
- **Escalation condition:** rises to **High** only if this API is internet-facing
  with no upstream proxy/gateway enforcing a body-size cap. That cannot be
  determined from the diff, so it is not assumed here.

### [INFO] CWE-613 — JWT has no expiry (`exp`) claim
- **File:** `internal/service/token_service.go:11-32` — **OUT OF DIFF SCOPE**
- **Note:** Tokens are HS256 with `sub` only and never expire; a leaked token is
  valid indefinitely (mitigated only by user deletion, since `RequireAuth`
  re-checks the subject exists). This file is the pre-existing auth slice / trust
  anchor and is **not** part of `main..HEAD` for this slice. Reported for
  awareness and attributed to the auth slice owner. **Non-blocking; does not route
  back to the Slice-3 coder** (outside their diff).

### [INFO] JSON decoder does not reject unknown fields
- **File:** `internal/handler/gameplay.go:157,294`
- **Note:** `json.Decoder` without `DisallowUnknownFields()` silently ignores
  extra keys. No security impact (no mass-assignment path — user_id is never
  bound from the body), but stricter decoding would catch client typos. Cosmetic.

### [INFO] Two-query ownership pattern (documented above, not a defect)
- **File:** `internal/store/record_store.go:62-65, 97-100`
- **Note:** Documented in §1. Safe due to immutable match→child ownership.
  Recorded so a re-reviewer sees it was deliberately checked.

## Dependency Audit
- Not re-run (verification gate already green per task: build/vet/golangci-lint/
  `go test -race ./...` pass against real Postgres). No new third-party imports
  introduced by this slice beyond `google/uuid`, `jackc/pgx/v5`, and the existing
  `golang-jwt/jwt/v5` — all already vetted in prior slices.

## Verdict
**PASS.** The primary risk (IDOR) is cleanly closed on all 7 routes: user_id is
sourced only from the verified JWT and enforced in the SQL predicate, queries are
fully parameterized, RequireAuth gates every route with 401-before-404, and the
404-not-403 no-leak invariant holds without exposing DB/internal error text. One
Medium (unbounded body/batch) and three Info items are hardening recommendations,
none blocking.

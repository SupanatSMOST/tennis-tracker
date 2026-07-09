# Code Review: Backend + Auth Foundation (Phase 1, Slice 1)

**Date:** 2026-07-09
**Reviewer:** reviewer (AI)
**Scope:** `ea88168..HEAD` under `tennis/backend/` only (22 commits). Cross-history noise (webapp/, python/, pokebot/) excluded per task instructions.
**Verdict:** APPROVE (ready for security audit) — with one low/medium finding described for the coder and two verification caveats.

## Verification performed
- `go build ./...` — pass
- `go vet ./...` — pass
- `DATABASE_URL=... go test ./...` — all packages pass (handler, service, store, config, migrations)
- `gofmt -l .` — 4 test files were misaligned; auto-fixed (see below), now clean
- `golangci-lint run` — **NOT RUN**: tool not installed in this environment (AC8 lint arm unverified)
- `goose up/down` — **NOT RUN**: goose not installed (AC1/AC7 verified by inspection only)
- No `fmt.Print`/`log.Print` in production code; no `gen_random_uuid()` in migrations (A-1 honored)

## Spec Compliance

**Schema**
- [x] AC1: migrations apply cleanly — verified by inspection (schema_test asserts final shape; goose not installed to run `up` directly)
- [x] AC2: all five tables exist — tested (`TestSchema_AC2_AllFiveTablesExist`)
- [x] AC3: column types/nullability — tested (`TestSchema_AC3_KeyColumnTypes`, spot-checks incl. REAL nullable, TEXT no-CHECK)
- [x] AC4: username UNIQUE — tested (`TestSchema_AC4_UsernameUnique`, 23505)
- [x] AC5: composite PK (match_id, zone), no surrogate — tested (`TestSchema_AC5_MatchSummaryCompositePK`)
- [x] AC6: four FKs exist — tested (`TestSchema_AC6_ForeignKeys` via pg_catalog)
- [~] AC7: `goose down` reverses cleanly — Down blocks present and correctly ordered (drops children before parents), but **not executed** (goose absent). Verified by inspection only.

**Server skeleton**
- [~] AC8: build/vet/lint pass — build and vet pass; **golangci-lint not run** (tool absent). Lint arm unverified.
- [x] AC9: cmd/ entrypoint, internal/{handler,service,store,model} layout — correct
- [x] AC10: pgx/v5, no ORM — confirmed in go.mod (pgx/v5 only; no gorm/ent/sqlc)
- [x] AC11: slog structured logging — JSON handler configured first in main; no fmt/log.Print
- [x] AC12: GET /health → 200 {"status":"ok"}, pure liveness (OQ-3) — tested (`TestHealth_NoDBProbe`)

**Auth**
- [x] AC13: signup creates row with bcrypt hash, returns per contract — tested; bcrypt cost 12
- [x] AC14: duplicate username → 409, no new row — tested (handler + store tx rollback)
- [x] AC15: login → 200 + JWT, sub = user_id, no exp — tested (`TestTokenService_NoExpClaim`, `TestLoginHandler_HappyPath`)
- [x] AC16: wrong password OR unknown username → 401 identical body — tested; service returns single `ErrInvalidCredentials`
- [x] AC17: HS256, key from env; wrong-key token rejected — tested (`TestRequireAuth_WrongKey`, token_service rejections)
- [x] AC18: GET /me valid Bearer → 200 {user_id, username} — tested
- [x] AC19: missing/malformed/bad-sig token → 401 — tested (multiple middleware cases incl. alg:none, RS256)
- [x] AC20: valid sig but sub not in DB → 401 — tested (`TestRequireAuth_UnknownSubject`, `TestRequireAuth_DeletedUser`)

**Gate-1 resolutions**
- OQ-1: signup inserts profile in same tx, display_name = username — CONFIRMED (`CreateUserWithProfile`)
- OQ-2: signup auto-login returns 201 {user_id, username, token} — CONFIRMED (handler + test asserts exact key set)
- OQ-3: /health pure liveness, no DB probe — CONFIRMED
- OQ-4: password < 8 runes / > 72 bytes rejected 400 before bcrypt — CONFIRMED (validation precedes GenerateFromPassword)

## Two design notes assessed

### Note 1 — Signup: no unwind if `tokens.Issue` fails after commit
**Verdict: ACCEPTABLE (INFO, not a finding).** Agree with the coder.
`Issue` calls `token.SignedString(hmacKey)`; HMAC signing has no per-request runtime failure mode with a valid key. A bad key is a boot-time misconfiguration (login would fail identically), not a per-user orphan. Recovery path exists: the user row and password hash are intact, so the user can simply log in. The only observable wart is a confusing 409 if the user retries signup. Not blocking.

### Note 2 — RequireAuth: all `GetUserByID` errors → 401 (including DB outage)
**Verdict: REAL FINDING (LOW/MEDIUM), not per-contract. Return to coder.**
`middleware.go:55-61` maps every `GetUserByID` error to 401, folding a DB outage into "unauthorized." Spec §6 enumerates the 401 triggers as *authentication* failures (bad header/token/signature, unknown sub) — a DB outage is not among them. The "uniform 401" reasoning over-reads the contract: the same codebase already distinguishes 500 for unexpected errors in the signup/login handler mappings (`auth.go`), so uniform-401 is not a codebase principle — it is specifically about not disclosing *which* auth reason failed (AC16-style non-disclosure), which does not extend to infra failures. Conflating a DB outage into 401 tells the client "re-authenticate" when it should back off and retry.
This is larger than a minor fix, so not auto-fixed. See finding below.

## Findings

### [LOW/MEDIUM] internal/handler/middleware.go:55-61 — DB error conflated with auth failure
- **Risk:** During a DB outage, `GET /me` (and every future protected route) returns 401 instead of 500. Clients interpret this as "credentials invalid" and may drop/rotate a valid token or force re-login, instead of backing off. It also masks infra failures in logs/metrics as auth noise.
- **Fix:** Distinguish the not-found case from unexpected errors:
  ```go
  u, err := s.GetUserByID(r.Context(), userID)
  if err != nil {
      if errors.Is(err, store.ErrUserNotFound) {
          writeError(w, http.StatusUnauthorized, "unauthorized") // AC20
          return
      }
      slog.Error("auth middleware: user lookup failed", "err", err)
      writeError(w, http.StatusInternalServerError, "internal server error")
      return
  }
  ```
  AC20 (deleted user → 401) is preserved by the `ErrUserNotFound` branch; existing tests remain green. Add a test for the DB-error → 500 path if practical (can be deferred, as it requires fault injection).
- **Blocking?** No. For a single-user app a DB outage means the whole app is down regardless; this is a correctness/observability improvement, not a security hole. Recommend fixing before the next protected-route slice lands so the pattern is right from the start.

## Auto-fixes Applied
- `gofmt -w` on struct-field alignment (pure whitespace) in:
  - `internal/handler/auth_handler_test.go`
  - `internal/handler/respond_test.go`
  - `internal/service/token_service_test.go`
  - `migrations/schema_test.go`
- Re-ran `go build ./...`, `go vet ./...`, and full `go test ./...` after formatting — all green.
- Staged only `tennis/backend/` paths; committed on `feat/tennis-phase1`.

## Notes for the security-auditor
- bcrypt cost 12 (`auth_service.go:65`); password_hash never has a json tag (`model/user.go`) and is never logged.
- JWT HS256 with double alg guard: `jwt.WithValidMethods(["HS256"])` plus a `*jwt.SigningMethodHMAC` type assertion in the keyfunc — blocks alg:none and RS/HS confusion. Tested.
- No `exp` claim by design (documented single-user non-expiring trade-off). No revocation machinery (explicitly out of scope).
- Login failure is indistinguishable (single `ErrInvalidCredentials` for both unknown-user and wrong-password).
- Signing key read from `JWT_SIGNING_KEY` env only; process fails loud on boot if unset/empty; key never logged.
- `defer tx.Rollback` is a safe no-op after Commit; unique-violation path rolls back both inserts.

## Summary
The slice is solid and faithful to the spec and all four Gate-1 resolutions: correct layered architecture (handler→service→store), pgx/v5 with app-side UUIDs, thorough test coverage across all 20 acceptance criteria, and defensively-implemented JWT verification. One non-blocking finding (middleware conflates DB errors with 401) should go back to the coder before the next protected-route slice. Two ACs (AC7 goose-down, AC8 golangci-lint) are verified by inspection only because the tools are absent from this environment — recommend running both in CI. Verdict: APPROVE for security audit.

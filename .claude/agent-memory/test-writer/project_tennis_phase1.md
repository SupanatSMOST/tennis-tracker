---
name: project-tennis-phase1
description: Tennis backend Phase 1 — 12-task plan on feat/tennis-phase1; test-writer covers tasks in order
metadata:
  type: project
---

Phase 1 backend auth foundation is being built incrementally across 12 tasks on branch `feat/tennis-phase1`. Tasks are dependency-ordered: skeleton → config → pool/respond → migrations → model → store → token service → auth service → handlers → middleware → /me → wire.

**Why:** Spec approved at Gate 1; each task is one coder pass, test-writer writes tests after each coder pass.

**How to apply:** When asked to test a task, read the corresponding task section in `docs/plans/tasks-backend-auth-foundation-2026-07-09.md` for the acceptance criteria and specific test instructions. The spec is at `docs/specs/spec-backend-auth-foundation-2026-07-09.md`.

Tasks requiring a real Postgres DB (Tasks 4, 6, 8, 10, 12): do not mock the DB — per [[feedback-live-truth]] pattern from the pokebot project.

Commit constraints: stage only `backend/internal/...` files by explicit path; never `git add -A`; do not stage the stray `backend/server` binary.

**Tested tasks:** Task 2 (config loader), Task 3 (respond helpers — commit 3800369), Task 4 (migrations schema — commit 9e2734a), Task 6 (user store — commit 7ca873b), Task 7 (token service — commit 960d6ea), Task 8 (auth service — commit d2d2dc1), Task 10 (auth middleware — commit 1e92e9e), Task 11 (/me handler — commit 95c995c), Task 12 (full wiring E2E — commit 90f2705). **Phase 1 complete.**

**Task 4 test location:** `backend/migrations/schema_test.go`, package `migrations_test`. Tests use pgx/v5 + pgconn (already in go.mod — no new deps). DB is at port 55432 (throwaway cluster).

**Task 7 test location:** `backend/internal/service/token_service_test.go`, package `service`. Pure unit tests (no DB). Tests: round-trip, no-exp claim (raw jwt.Parse to inspect MapClaims), and 5 Parse rejection cases (wrong key, alg:none, RS256, malformed, non-UUID sub). All 7 pass.

**Task 8 test location:** `backend/internal/service/auth_service_test.go`, package `service_test` (external — avoids `signingKey` collision with token_service_test.go). Integration tests against real Postgres (port 55432). 6 tests: signup happy path (bcrypt hash stored + token sub round-trips), signup→login round-trip, wrong-password ErrInvalidCredentials, unknown-username same ErrInvalidCredentials (AC16), four OQ-4 password-policy boundaries (7-rune fail / 8-rune pass / 72-byte pass / 73-byte fail, with errors.As ValidationError), duplicate-username ErrUsernameTaken propagation. All 6 pass. ValidationError is detectable via errors.As — no gap found.

**Task 10 test location:** `backend/internal/handler/middleware_test.go`, package `handler` (internal — needed to call unexported `userFromContext`). Helpers prefixed `mw` to avoid collision with `respond_test.go`. 11 tests: missing header, Basic scheme, Bearer with no token, Bearer with empty token, wrong key (AC19), alg:none (AC19), RS256 confusion (AC19), malformed garbage (AC19), unknown sub never-inserted (AC20), valid token for existing user with context assertion (AC18), create-then-delete user (AC20). All 11 pass.

**Task 11 test location:** `backend/internal/handler/me_test.go`, package `handler` (internal). Context injection via `context.WithValue(ctx, authedUserKey{}, AuthedUser{...})` — no DB needed. 2 tests: TestMe_HappyPath (200 + exact body with uuid + username), TestMe_MissingContext (defensive 401 reusing `assertUnauthorized` from middleware_test.go). Both pass. No new helpers declared at package level to avoid collision.

**Task 12 test location:** `backend/internal/handler/router_e2e_test.go`, package `handler_test` (external black-box). Builds real pgxpool + Store + TokenService + AuthService + AuthHandler + BuildRouter → httptest.NewServer. 8 tests: TestRouter_Health (AC12), TestRouter_SignupLoginMe (AC13+AC15+AC18 flow: signup 201+token, login 200+token JWT sub/no-exp verified, GET /me 200 matching user), TestRouter_MeBadToken (AC19 wrong-key), TestRouter_MeNoToken (AC19 no header), TestRouter_HealthNoToken (routing sanity: health unauthed, /me authed), TestRouter_SignupDuplicateUsername (AC14 409), TestRouter_LoginInvalidCredentials (AC16: wrong-pw + unknown-user both 401 same body), TestRouter_WrongMethodOnHealth (405 on method mismatch). All pass. Helpers prefixed `e2e` to avoid collision. Cleanup registers pool.Close AFTER DELETE cleanups (LIFO t.Cleanup ordering). JSON bodies decoded into structs, not byte-compared.

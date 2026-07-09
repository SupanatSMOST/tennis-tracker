# Tasks: Backend + Auth Foundation (Phase 1, Slice 1)

**Plan:** `docs/plans/plan-backend-auth-foundation-2026-07-09.md`
**Spec:** `docs/specs/spec-backend-auth-foundation-2026-07-09.md` (Gate-1 approved)
**Total tasks:** 12
**Branch:** `feat/tennis-phase1`. All work confined to `backend/` (plus these docs). No work outside `tennis/`.

> Order is dependency-driven: skeleton → config → pool+slog → migrations → model →
> store → token service → auth service → health/signup/login handlers → middleware →
> /me → router wiring. Migrations are a standalone task (never combined with app code).
> Each task is one coder pass (≤ ~200 lines new code).

---

## Task 1: Go module skeleton
**Layer:** backend
**Files to create/modify:**
- `backend/go.mod` — `go mod init github.com/Supanat-Smost/tennis/backend`; set `go 1.22` (or later). **Do NOT add the pgx/jwt/bcrypt/uuid deps here** — each dependency enters `go.mod` in the task that first imports it (uuid/pgx in Task 6, jwt in Task 7, bcrypt in Task 8), because an empty module + `go mod tidy` would strip any unimported `require`.
- `backend/cmd/server/main.go` — minimal `package main` with a trivially-compiling `main()` (real wiring lands in Task 12).
**Depends on:** none
**Acceptance:** `go build ./...` and `go vet ./...` pass from `backend/`. `go.mod` declares the module path + `go 1.22`. No deps added yet (correct — they arrive as they are imported). **No ORM will ever be added** (AC10 is verified at Task 12's build once real deps are present).
**Test:** none yet (no logic). Verify build/vet green. Covers AC8 (partial).

## Task 2: Config loader
**Layer:** backend
**Files to create/modify:**
- `backend/internal/config/config.go` — `Config{ DatabaseURL string; JWTSigningKey []byte; Port string }` and `Load() (Config, error)`. Read `DATABASE_URL` (required, non-empty), `JWT_SIGNING_KEY` (required, non-empty), `PORT` (optional, default `"8080"`). Return a clear error naming the missing var; do not log the signing key.
**Depends on:** Task 1
**Acceptance:** `Load()` returns an error when `DATABASE_URL` or `JWT_SIGNING_KEY` is unset/empty; returns `Port="8080"` when `PORT` unset. No secret defaults in code (FR-B7, spec §7).
**Test:** table test over env permutations: missing DATABASE_URL → error; missing JWT_SIGNING_KEY → error; empty JWT_SIGNING_KEY → error; all set → ok with correct fields; PORT unset → `8080`. Use `t.Setenv`.

## Task 3: DB pool + slog bootstrap helpers
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/store.go` — `Store` struct wrapping `*pgxpool.Pool`; `func New(pool *pgxpool.Pool) *Store`. (Pool construction from `DATABASE_URL` happens in `main` — Task 12 — via `pgxpool.New`; this task defines the wrapper and constructor only.)
- `backend/internal/handler/respond.go` — `writeJSON(w, status, v)` and `writeError(w, status, msg)` (writes `{"error": msg}`). Encode with `encoding/json`; set `Content-Type: application/json`.
**Depends on:** Task 1
**Acceptance:** package compiles; `writeError` produces exactly `{"error":"<msg>"}`; `writeJSON` sets status + content-type. slog is configured in `main` (Task 12), not here — this task just avoids `fmt.Print`/`log.Print` (AC11).
**Test:** unit test `writeError`/`writeJSON` via `httptest.ResponseRecorder`: assert status code, `Content-Type`, and exact JSON body.

## Task 4: Migrations — auth + gameplay tables
**Layer:** migration
**Files to create/modify:**
- `backend/migrations/00001_auth_tables.sql` — goose up/down for `user_login`, `profile` (per plan §3 DDL). `user_id` UUID PK, `username TEXT NOT NULL UNIQUE`, `password_hash TEXT NOT NULL`, `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`; `profile` PK/FK → `user_login`, `display_name TEXT NOT NULL`, `avatar_url TEXT` (nullable), `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`. Down drops `profile` then `user_login`.
- `backend/migrations/00002_gameplay_tables.sql` — goose up/down for `match`, `record`, `match_summary` (per plan §3 DDL). Composite PK `(match_id, zone)` on `match_summary`, no surrogate id. FKs `match.user_id→user_login`, `record.match_id→match`, `match_summary.match_id→match`. Down drops `match_summary`, `record`, `match` (reverse-FK order).
**Depends on:** none (pure SQL; independent of Go tasks — but keep as its own task, never combined with app code)
**Acceptance:** `goose -dir backend/migrations postgres "$DATABASE_URL" up` → exit 0, all five tables exist (AC1, AC2). `goose ... down` twice → empty schema, exit 0 (AC7). No `DEFAULT gen_random_uuid()` anywhere (A-1). `zone`/`source`/`court_surface` are plain `TEXT`, no CHECK/enum (A-4). FKs default `ON DELETE NO ACTION` (A-2).
**Test:** against a real (throwaway/CI) Postgres: run `up`, assert five tables + `username` UNIQUE (AC4) + composite PK on `match_summary` (AC5) + four FKs present (AC6) via `information_schema`; insert duplicate username fails; run `down` twice → empty. Do not mock the DB.

## Task 5: Domain model types
**Layer:** backend
**Files to create/modify:**
- `backend/internal/model/user.go` — `User{ UserID uuid.UUID; Username string; PasswordHash string; CreatedAt time.Time }` and `Profile{ UserID uuid.UUID; DisplayName string; AvatarURL *string; UpdatedAt time.Time }`. No JSON tags on domain types (client DTOs live in the handler package so `PasswordHash` is never marshaled).
**Depends on:** Task 1
**Acceptance:** compiles; `AvatarURL` is a pointer (nullable). Domain types carry no `json:` serialization of `PasswordHash`.
**Test:** none (plain structs). Compilation is the check.

## Task 6: User store (queries + signup transaction)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/user_store.go` — three methods on `*Store`, all taking `ctx` first:
  - `CreateUserWithProfile(ctx, u model.User) error` — `pool.Begin` → `INSERT user_login(user_id, username, password_hash)` → `INSERT profile(user_id, display_name, avatar_url)` with `display_name = u.Username`, `avatar_url = NULL` → `Commit`; rollback on any error. Map `*pgconn.PgError` code `23505` → `ErrUsernameTaken`.
  - `GetUserByUsername(ctx, username) (model.User, error)` — `pgx.ErrNoRows` → `ErrUserNotFound`.
  - `GetUserByID(ctx, id uuid.UUID) (model.User, error)` — `pgx.ErrNoRows` → `ErrUserNotFound`.
- Define sentinel errors `ErrUsernameTaken`, `ErrUserNotFound` in the store package.
**Depends on:** Task 3 (Store), Task 5 (model), Task 4 (schema must exist to test)
**Acceptance:** SELECTs read `created_at` (DB `DEFAULT now()`); inserts do not set timestamps. Duplicate username → `ErrUsernameTaken`; the tx leaves **no** `user_login` or `profile` row on rollback (AC14). Unknown lookups → `ErrUserNotFound`.
**Test:** integration against real Postgres (migrated via Task 4): create user → assert one `user_login` **and** one `profile` row with `display_name = username`; create duplicate → `ErrUsernameTaken` and row count unchanged in both tables; `GetUserByUsername`/`GetUserByID` round-trip and not-found path. No DB mocks.

## Task 7: Token service (HS256 issue/verify + alg guard)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/service/token_service.go` — `TokenService{ key []byte }`, `NewTokenService(key []byte)`. `Issue(userID uuid.UUID) (string, error)` builds an HS256 JWT with `sub = userID.String()` and **no `exp`**. `Parse(token string) (uuid.UUID, error)` verifies signature, rejects any alg != HS256 via `jwt.WithValidMethods([]string{"HS256"})` + an HMAC method assertion in the keyfunc, and parses `sub` back to `uuid.UUID`.
**Depends on:** Task 1
**Acceptance:** issued token decodes to `sub` = the UUID and contains **no** `exp` claim (AC15). `Parse` rejects: wrong key, `alg:none`, RS256 token, malformed token, non-UUID sub (AC17).
**Test:** round-trip Issue→Parse returns same UUID. Assert no `exp` in claims. Parse with a token signed by a different key → error; a hand-crafted `alg:none` token → error; an RS256-header token → error. Pure unit tests (no DB).

## Task 8: Auth service (signup + login orchestration)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/service/auth_service.go` — `AuthService{ store *store.Store; tokens *TokenService }` + constructor.
  - `Signup(ctx, username, password string) (model.User, string, error)`: validate password (`< 8` runes → validation error; `> 72` bytes → validation error) **before** bcrypt; `bcrypt.GenerateFromPassword([]byte(pw), 12)`; `uuid.New()`; `store.CreateUserWithProfile`; then `tokens.Issue`. Propagate `ErrUsernameTaken`.
  - `Login(ctx, username, password string) (string, error)`: `store.GetUserByUsername`; on `ErrUserNotFound` return `ErrInvalidCredentials`; `bcrypt.CompareHashAndPassword`; on mismatch return the **same** `ErrInvalidCredentials`; success → `tokens.Issue`.
- Define `ErrInvalidCredentials` and a validation error type (carrying a 400-appropriate message) in the service package.
**Depends on:** Task 6 (store), Task 7 (tokens)
**Acceptance:** signup persists a bcrypt hash (never plaintext) (AC13); password `< 8` runes and `> 72` bytes both rejected before bcrypt (OQ-4); unknown user and wrong password both yield the identical `ErrInvalidCredentials` (AC16).
**Test:** integration (real DB): signup then login round-trips a token; login wrong password → `ErrInvalidCredentials`; login unknown user → **same** `ErrInvalidCredentials`; password of 7 chars → validation error; password of 73 bytes → validation error; stored `password_hash` != plaintext and verifies with bcrypt.

## Task 9: Health + auth handlers (health, signup, login)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/health.go` — `GET /health` → `200 {"status":"ok"}`. No DB probe (OQ-3).
- `backend/internal/handler/auth.go` — signup + login handlers. Local DTOs: `signupRequest{Username,Password}`, `loginRequest{...}`, `authResponse{UserID,Username,Token}` (signup 201), `tokenResponse{Token}` (login 200). Decode JSON (malformed → `400`); empty username/password → `400`. Map service errors to status:
  - signup: `ErrUsernameTaken` → `409 {"error":"username already taken"}`; validation error → `400 {"error":"<reason>"}`; success → `201 {user_id, username, token}`.
  - login: `ErrInvalidCredentials` → `401 {"error":"invalid credentials"}`; validation/empty → `400`; success → `200 {token}`.
  Use `writeJSON`/`writeError` from Task 3.
**Depends on:** Task 8 (auth service), Task 3 (respond helpers)
**Acceptance:** `/health` → `200 {"status":"ok"}` (AC12). Signup happy path `201 {user_id,username,token}` (AC13, OQ-2). Duplicate username → `409 {"error":"username already taken"}` (AC14). Login success `200 {token}` (AC15 transport). Login failure `401 {"error":"invalid credentials"}` (AC16). Malformed/empty bodies → `400`.
**Test:** `httptest` handler tests with a real (or integration) auth service: assert exact status codes and exact bodies for each path above, including the two 400 password-policy paths surfaced through signup.

## Task 10: Auth middleware + context
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/middleware.go` — `RequireAuth(tokens *service.TokenService, s *store.Store) func(http.Handler) http.Handler`. Reads `Authorization`, requires `Bearer ` prefix (missing/malformed → `401`); `tokens.Parse` (bad sig / wrong alg / malformed → `401`); `s.GetUserByID` (not found → `401`, AC20); on success injects `AuthedUser{UserID,Username}` into `context` under a private key type. Provide `userFromContext(ctx) (AuthedUser, bool)`. All failures → `401 {"error":"unauthorized"}` via `writeError`.
**Depends on:** Task 7 (tokens), Task 6 (store), Task 3 (respond)
**Acceptance:** missing/malformed header → `401`; bad-signature/wrong-alg/malformed token → `401` (AC19); valid signature but `sub` not in `user_login` → `401` (AC20); valid token → next handler runs with `AuthedUser` in context. Uniform body `{"error":"unauthorized"}`.
**Test:** integration (real DB for the GetUserByID resolve): wrap a stub handler; assert `401` for no header, `Bearer` without token, token signed with wrong key, `alg:none` token, and a valid token whose UUID was deleted; assert `200` + context populated for a valid token of an existing user.

## Task 11: /me protected handler
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/me.go` — `GET /me` handler: read `AuthedUser` from context via `userFromContext`; return `200 {user_id, username}`. No DB query (middleware already resolved the user).
**Depends on:** Task 10 (middleware + context accessor)
**Acceptance:** with context populated by `RequireAuth`, returns `200 {"user_id":"<uuid>","username":"<string>"}` (AC18). Does not query the DB itself.
**Test:** `httptest` with a request carrying a pre-populated `AuthedUser` context: assert `200` and exact body. (End-to-end through the real middleware is covered in Task 10 / Task 12 wiring.)

## Task 12: Wire everything in main (router, pool, slog, listen)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/router.go` — `BuildRouter(...) http.Handler` using stdlib `net/http.ServeMux`: `GET /health`, `POST /auth/signup`, `POST /auth/login`, and `GET /me` wrapped in `RequireAuth`.
- `backend/cmd/server/main.go` — `config.Load()` (fatal on error); build `slog` JSON handler + `slog.SetDefault`; `pgxpool.New(ctx, cfg.DatabaseURL)` (fatal on error); construct `store.New`, `NewTokenService(cfg.JWTSigningKey)`, `AuthService`, handlers, middleware; `http.ListenAndServe(":"+cfg.Port, router)`. All logging via `slog`; never log the signing key or passwords.
**Depends on:** Tasks 2, 3, 7, 8, 9, 10, 11
**Acceptance:** `go build ./...`, `go vet ./...`, `golangci-lint run ./...` all pass (AC8). Entrypoint under `cmd/server`; layered packages under `internal/*` (AC9). slog JSON at startup, no `fmt.Print`/`log.Print` (AC11). Process fails loudly if `DATABASE_URL`/`JWT_SIGNING_KEY` missing (FR-B7). Server boots and serves all four routes.
**Test:** end-to-end smoke against a booted server + real migrated DB (or `httptest.NewServer` with the built router + real DB): signup → 201 with token; login → 200 with token; `/me` with that token → 200; `/me` with a token signed by a different key → 401; `/health` → 200. This exercises AC12–AC20 through the real wiring.

---

## AC → Task coverage matrix

| AC | Task(s) |
|---|---|
| AC1 (goose up clean) | 4 |
| AC2 (five tables) | 4 |
| AC3 (columns/types/nullability) | 4 |
| AC4 (username UNIQUE) | 4 |
| AC5 (composite PK match_summary) | 4 |
| AC6 (four FKs) | 4 |
| AC7 (goose down clean) | 4 |
| AC8 (build/vet/lint) | 1, 12 |
| AC9 (layout) | 1, 12 |
| AC10 (pgx, no ORM) | 6 (adds pgx), 12 (build confirms no ORM) |
| AC11 (slog) | 12 |
| AC12 (/health 200) | 9 |
| AC13 (signup bcrypt + 201+token) | 8, 9 |
| AC14 (dup → 409, no row) | 6, 9 |
| AC15 (login 200 + jwt, sub, no exp) | 7, 9 |
| AC16 (indistinguishable 401) | 8, 9 |
| AC17 (HS256 + alg guard) | 7 |
| AC18 (/me 200 with user) | 10, 11 |
| AC19 (bad token → 401) | 10 |
| AC20 (unknown sub → 401) | 10 |

Every AC1–AC20 maps to at least one task; no orphans.

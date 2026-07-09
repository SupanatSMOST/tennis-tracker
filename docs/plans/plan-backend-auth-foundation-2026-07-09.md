# Plan: Backend + Auth Foundation (Phase 1, Slice 1)

**Spec:** `docs/specs/spec-backend-auth-foundation-2026-07-09.md` (Gate-1 approved)
**Date:** 2026-07-09
**Author:** architect (AI)

> **Gate-1 resolutions baked in (override the spec's baseline assumptions where they differ):**
> - **OQ-1 = YES:** `POST /auth/signup` eagerly inserts the 1:1 `profile` row with `display_name = username`, in the **same transaction** as the `user_login` insert (both commit or both roll back).
> - **OQ-2 = AUTO-LOGIN:** `POST /auth/signup` returns `201 + { user_id, username, token }` — the same JWT `login` issues. `login` remains a token issuer too.
> - **OQ-3 = PURE LIVENESS:** `GET /health` returns `200` whenever the process is up; it never probes the DB. No `503` path this slice.
> - **OQ-4 = PASSWORD POLICY:** signup rejects passwords with fewer than 8 characters (runes) AND passwords longer than 72 bytes, both `400`. Validation runs **before** bcrypt, so bcrypt's silent 72-byte truncation is never reached.

---

## 0. Non-goals (carried forward from spec §2)

Explicitly **not** built this slice (schema for gameplay tables is created, but nothing else):
- **No iOS / Swift** — deferred to a later Phase 1 slice.
- **No CV pipeline / Python** — deferred to Phase 3.
- **No CRUD for `match` / `record` / `match_summary`** beyond `GET /me` — tables exist, business endpoints deferred.
- **No `match_summary` aggregation/rebuild routine** — schema only; end-of-match aggregation deferred.
- **No profile CRUD endpoints** — the row is seeded at signup (OQ-1), but read/update endpoints are deferred.
- **No token revocation / server-side logout machinery** — accepted trade-off for a non-expiring token.

## 1. Architecture Overview

A single Go module rooted at `backend/go.mod` exposes a small HTTP API in the locked
CLAUDE.md layout. Requests flow strictly one direction: **handler → service → store**.
Handlers own HTTP concerns (JSON decode/encode, status codes, uniform error shape);
services own business logic (password hashing, JWT issue/verify, the signup
transaction, user lookup); stores own all `pgx/v5` SQL against PostgreSQL via a shared
`pgxpool.Pool`. Config is loaded once from environment at boot (`DATABASE_URL`,
`JWT_SIGNING_KEY`, `PORT`), and any missing required var fails the process loudly
before it serves a request. Logging is structured `slog` throughout. Authentication is
username/password with bcrypt (cost 12) and a **non-expiring HS256 JWT** whose `sub` is
the `user_id` UUID; an auth middleware verifies the token (with an algorithm guard),
resolves the full user row from the DB, and injects it into the request context so the
one protected route (`GET /me`) can echo `user_id` + `username` without a second query.
All five DESIGN.md tables are created now via goose migrations (schema complete and
stable), but only `user_login` and `profile` are written this slice; gameplay CRUD and
the `match_summary` aggregation routine are explicit non-goals.

## 2. Component Design

### 2.1 Backend (Go)

Module path: `github.com/Supanat-Smost/tennis/backend` (a stable, importable module
path; adjust the org segment only if the repo remote differs — it does not change any
package layout below).

**Package layout (all new; backend is greenfield):**

```
backend/
├── go.mod                          # module + pinned deps (§ go.mod deps)
├── go.sum
├── cmd/
│   └── server/
│       └── main.go                 # entrypoint: load config, build pool+logger, wire router, ListenAndServe
├── internal/
│   ├── config/
│   │   └── config.go               # Config struct + Load() from env; fail-loud on missing required vars
│   ├── model/
│   │   └── user.go                 # domain types: User, Profile, Claims-free (see below)
│   ├── store/
│   │   ├── store.go                # Store struct wrapping *pgxpool.Pool; constructor
│   │   └── user_store.go           # CreateUserWithProfile (tx), GetUserByUsername, GetUserByID
│   ├── service/
│   │   ├── auth_service.go         # Signup, Login, hashing, credential compare, orchestration
│   │   └── token_service.go        # Issue(userID) / Parse(tokenString) HS256 + alg guard
│   ├── handler/
│   │   ├── router.go               # BuildRouter(handlers, mw) -> http.Handler; route table
│   │   ├── health.go               # GET /health
│   │   ├── auth.go                 # POST /auth/signup, POST /auth/login
│   │   ├── me.go                   # GET /me (protected)
│   │   ├── middleware.go           # RequireAuth middleware; context key + accessor
│   │   └── respond.go              # writeJSON / writeError helpers (uniform {"error": "..."} shape)
│   └── migrations embedded? — NO. Migrations live at backend/migrations/ and are run by goose CLI (AC1), not embedded.
└── migrations/                     # see §3
```

**Router choice:** Go 1.22+ standard-library `net/http.ServeMux` with
method+pattern routes (e.g. `mux.HandleFunc("GET /health", ...)`,
`mux.Handle("GET /me", requireAuth(meHandler))`). Rationale: zero extra dependency,
native method routing, matches the "no ORM / lightweight" ethos. Set Go `1.22`
(or later) in `go.mod` so pattern routing is available. `RequireAuth` is applied per
route (wrap only `/me`), not globally, so public routes stay open.

**pgx/pgxpool wiring:** `main.go` calls `pgxpool.New(ctx, cfg.DatabaseURL)` once at
boot; on error the process logs via `slog` and exits non-zero (FR-B6/FR-B7). The
`*pgxpool.Pool` is handed to `store.New(pool)`. The store is the only package that
imports `pgx`. Query methods take `context.Context` as the first arg and use
`pool.QueryRow` / `pool.Begin` (see the signup transaction below).

**slog setup:** `main.go` builds one handler at startup —
`slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))`
— and sets it via `slog.SetDefault`. All logging goes through `slog` (AC11). The
`JWT_SIGNING_KEY` and password plaintext are **never** logged.

**Config loading (`internal/config`):**

```go
type Config struct {
    DatabaseURL   string // DATABASE_URL   (required)
    JWTSigningKey []byte // JWT_SIGNING_KEY (required, non-empty)
    Port          string // PORT           (optional, default "8080")
}

// Load reads env, returns error if DATABASE_URL or JWT_SIGNING_KEY is missing/empty.
func Load() (Config, error)
```

`main.go` treats a `Load()` error as fatal (log + `os.Exit(1)`).

**Key types (`internal/model`):**

```go
type User struct {
    UserID       uuid.UUID
    Username     string
    PasswordHash string      // bcrypt string; never serialized to clients
    CreatedAt    time.Time
}

type Profile struct {
    UserID      uuid.UUID
    DisplayName string
    AvatarURL   *string     // nullable
    UpdatedAt   time.Time
}
```

Handler-facing JSON DTOs (request/response) are defined locally in `internal/handler`
(e.g. `signupRequest`, `authResponse{ UserID, Username, Token }`, `meResponse`), so the
domain `User` (which carries `PasswordHash`) is never marshaled to a client.

**Token service (`internal/service/token_service.go`):**

```go
type TokenService struct{ key []byte }

func NewTokenService(key []byte) *TokenService
// Issue builds an HS256 JWT with claims {sub: userID.String()} and NO exp claim.
func (s *TokenService) Issue(userID uuid.UUID) (string, error)
// Parse verifies signature + REJECTS any alg != HS256 (jwt.WithValidMethods),
// then returns the sub UUID. Returns error on bad sig, wrong alg, malformed token,
// or unparseable sub.
func (s *TokenService) Parse(token string) (uuid.UUID, error)
```

The alg guard uses `golang-jwt`'s `jwt.WithValidMethods([]string{"HS256"})` parse
option plus a keyfunc that additionally asserts `*jwt.SigningMethodHMAC` — this defeats
`alg:none` and RS/HS confusion (AC17).

**Auth service (`internal/service/auth_service.go`):**

```go
type AuthService struct {
    store  *store.Store
    tokens *TokenService
}

// Signup: validate password policy (min 8 runes, max 72 bytes) -> bcrypt hash (cost 12)
// -> generate uuid.New() -> store.CreateUserWithProfile (single tx) -> Issue token.
// Returns (User, token, error). Duplicate username surfaces as a typed ErrUsernameTaken.
func (s *AuthService) Signup(ctx, username, password string) (model.User, string, error)

// Login: GetUserByUsername -> bcrypt.CompareHashAndPassword -> Issue token.
// Unknown user AND wrong password both return the SAME typed ErrInvalidCredentials.
func (s *AuthService) Login(ctx, username, password string) (string, error)
```

Typed sentinel errors (`ErrUsernameTaken`, `ErrInvalidCredentials`, and a validation
error type carrying a 400 message) live in the service package; handlers map them to
HTTP status codes. This keeps handlers thin and the status mapping in one place.

**Signup transaction (the OQ-1 consequence):** `store.CreateUserWithProfile` opens a
transaction, inserts the `user_login` row, then inserts the `profile` row
(`display_name = username`, `avatar_url = NULL`, `updated_at = now()`), then commits.
Any error rolls back so AC14 ("creates no new row") holds for both tables. **Reconciles
spec A-3**, which was written pre-OQ-1 and said "only writes `user_login.created_at`" —
under OQ-1 signup now also writes the three `profile` columns above.

**409 detection:** rely on the `user_login.username` UNIQUE constraint. On insert,
inspect the pgx error; if it is a `*pgconn.PgError` with `Code == "23505"`
(unique_violation), the store returns `ErrUsernameTaken`, which the handler maps to
`409`. No pre-check `SELECT` (avoids a TOCTOU race and an extra round trip).

**`created_at` write strategy:** app does **not** set timestamps; the DDL gives
`created_at`/`updated_at` a `DEFAULT now()` (see §3). UUIDs remain **app-side**
(`uuid.New()`, spec A-1) — no `gen_random_uuid()` default. This split is deliberate and
consistent: identity is app-owned; wall-clock stamps are DB-owned.

**Store methods (`internal/store/user_store.go`):**

```go
func (s *Store) CreateUserWithProfile(ctx context.Context, u model.User) error // tx; maps 23505 -> ErrUsernameTaken
func (s *Store) GetUserByUsername(ctx context.Context, username string) (model.User, error) // pgx.ErrNoRows -> ErrUserNotFound
func (s *Store) GetUserByID(ctx context.Context, id uuid.UUID) (model.User, error)          // pgx.ErrNoRows -> ErrUserNotFound
```

**Auth middleware + context (`internal/handler/middleware.go`) — the `/me` seam:**
`RequireAuth(tokens *service.TokenService, store *store.Store)` returns a
`func(http.Handler) http.Handler`. It:
1. Reads `Authorization` header; requires the `Bearer ` prefix. Missing/malformed → `401`.
2. `tokens.Parse(token)` → `user_id` (this enforces the HS256 alg guard). Bad sig / wrong alg / malformed → `401` (AC17, AC19).
3. `store.GetUserByID(ctx, userID)`; if not found (`ErrUserNotFound`) → `401` (AC20 — resolves the row, not just the signature).
4. On success, injects the **resolved user (id + username)** into the request context
   under a private key type, then calls the next handler.

Context key is a private, unexported type to avoid collisions:

```go
type ctxKey struct{}
type AuthedUser struct { UserID uuid.UUID; Username string }
func userFromContext(ctx context.Context) (AuthedUser, bool)
```

`GET /me` reads `AuthedUser` from context and returns `{ user_id, username }` — **no
second DB query** (the middleware already resolved it). All middleware failure paths
return the uniform body `{"error":"unauthorized"}`.

**Uniform responses (`internal/handler/respond.go`):** `writeJSON(w, status, v)` and
`writeError(w, status, msg)` (the latter writes `{"error": msg}`). Every handler uses
these so the error shape is consistent (spec §6).

### 2.2 iOS (Swift)

**N/A** — explicit non-goal for this slice. No Swift code, no `ios/` changes.

### 2.3 CV Pipeline (Python)

**N/A** — explicit non-goal for this slice. No Python code, no `cv/` changes.

## 3. Data Model Changes

Full DDL for all five DESIGN.md tables. Split into **two goose migrations** (spec A-5):
auth tables first, gameplay tables second. This keeps FK dependency order clean and
lets the down steps reverse in strict reverse-FK order (AC7). No
`DEFAULT gen_random_uuid()` anywhere (UUIDs are app-side, A-1). Timestamp columns get
`DEFAULT now()` where the app relies on it (`user_login.created_at`,
`profile.updated_at`); gameplay timestamp columns are created as-declared with
`DEFAULT now()` for consistency (their write behavior is finalized when their endpoints
land — spec A-3). `zone`, `source`, `court_surface` are plain `TEXT` — no enums, no
CHECK (spec A-4). FKs use PostgreSQL default `ON DELETE NO ACTION` (spec A-2).

**Migration 1** — `backend/migrations/00001_auth_tables.sql`

```sql
-- +goose Up
CREATE TABLE user_login (
    user_id       UUID        PRIMARY KEY,
    username      TEXT        NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE profile (
    user_id      UUID        PRIMARY KEY REFERENCES user_login(user_id),
    display_name TEXT        NOT NULL,
    avatar_url   TEXT,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE profile;
DROP TABLE user_login;
```

**Migration 2** — `backend/migrations/00002_gameplay_tables.sql`

```sql
-- +goose Up
CREATE TABLE match (
    match_id      UUID        PRIMARY KEY,
    user_id       UUID        NOT NULL REFERENCES user_login(user_id),
    location      TEXT,
    court_surface TEXT,
    played_at     TIMESTAMPTZ,
    video_ref     TEXT,
    ended_at      TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE record (
    record_id  UUID        PRIMARY KEY,
    match_id   UUID        NOT NULL REFERENCES match(match_id),
    zone       TEXT,
    court_x    REAL,
    court_y    REAL,
    ts_ms      INTEGER,
    source     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE match_summary (
    match_id    UUID        NOT NULL REFERENCES match(match_id),
    zone        TEXT        NOT NULL,
    shot_count  INTEGER     NOT NULL,
    computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (match_id, zone)
);

-- +goose Down
DROP TABLE match_summary;
DROP TABLE record;
DROP TABLE match;
```

**Nullability policy (AC3).** AC3 governs which *columns exist* and honors the
nullability DESIGN.md *explicitly states*; DESIGN.md is silent on nullability for most
columns. The explicit rule applied here, stated so nothing is silently baked:

1. **Columns DESIGN.md marks `NOT NULL`** → `NOT NULL`: `user_login.username`,
   `user_login.password_hash`.
2. **Columns DESIGN.md marks `(nullable)`** → nullable: `profile.avatar_url`,
   `match.video_ref`, `match.ended_at`, `record.court_x`, `record.court_y`,
   `record.ts_ms`.
3. **FK / PK-participating columns** → `NOT NULL` (a FK/PK column that is null is
   meaningless): `profile.user_id`, `match.user_id`, `record.match_id`,
   `match_summary.match_id`, `match_summary.zone`, `match_summary.shot_count`.
   `profile.display_name` is also `NOT NULL` — OQ-1 guarantees signup always writes it
   (`= username`), so it can never be null in practice.
4. **Optional descriptive columns DESIGN.md is silent on** → **nullable** (no
   `NOT NULL` added): `match.location`, `match.court_surface`, `match.played_at`,
   `record.zone`, `record.source`. Their write-time constraints are finalized when
   their (out-of-scope) endpoints land.
5. **Timestamp columns** (`created_at`/`updated_at`/`computed_at`) → `NOT NULL DEFAULT
   now()` — the `DEFAULT now()` choice A-3 permits; not a new column.

None of this adds a column beyond §5 or enforces a *value* set (A-4 — `zone`/`source`/
`court_surface` remain plain `TEXT` with no enum/CHECK); rules 3–5 only govern
*presence*.

**Down order (AC7):** each migration's `-- +goose Down` drops in reverse-FK order —
`match_summary`, `record`, then `match` in migration 2; `profile` then `user_login` in
migration 1. Running `goose down` once per migration (2 steps) returns to an empty
schema, exit 0.

## 4. API Contract

All bodies JSON. Uniform error shape `{"error": "<message>"}`. Exact literals below are
testable (carried verbatim into task acceptance criteria).

### `GET /health`
- **Request:** none.
- **200 OK:** `{"status":"ok"}` — whenever the process is up. **No DB probe, no 503** (OQ-3).

### `POST /auth/signup`
- **Request:** `{ "username": string, "password": string }`
- **201 Created:** `{ "user_id": "<uuid>", "username": "<string>", "token": "<jwt>" }` (OQ-2 auto-login).
- **400 Bad Request:** malformed JSON; missing/empty `username`; missing/empty `password`;
  password shorter than 8 characters; password longer than 72 bytes — `{"error":"<reason>"}`.
- **409 Conflict:** username already taken — `{"error":"username already taken"}`.

### `POST /auth/login`
- **Request:** `{ "username": string, "password": string }`
- **200 OK:** `{ "token": "<jwt>" }`
- **400 Bad Request:** malformed JSON or missing/empty fields — `{"error":"<reason>"}`.
- **401 Unauthorized:** wrong password OR unknown username — identical body
  `{"error":"invalid credentials"}` (no account-existence leak, AC16).

### `GET /me` (protected)
- **Headers:** `Authorization: Bearer <jwt>`
- **200 OK:** `{ "user_id": "<uuid>", "username": "<string>" }`
- **401 Unauthorized:** missing/malformed header, malformed token, bad signature,
  non-HS256 alg, or `sub` UUID not in `user_login` — `{"error":"unauthorized"}`.

**JWT:** HS256, `sub` = `user_id` UUID string, **no `exp` claim** (non-expiring).
Signing key from `JWT_SIGNING_KEY`. Same token shape issued by both signup and login.

## 5. Sequence Diagrams (text)

**Signup (auto-login, single transaction):**
1. Client `POST /auth/signup {username, password}`.
2. Handler decodes JSON; on malformed body → `400`.
3. Handler calls `AuthService.Signup`.
4. Service validates password: `< 8` runes → 400; `> 72` bytes → 400 (before bcrypt).
5. Service `bcrypt.GenerateFromPassword(pw, 12)`; generates `uuid.New()`.
6. Store `Begin` tx → `INSERT user_login` → `INSERT profile (display_name=username)` → `Commit`.
7. Unique violation (23505) on user_login → rollback → `ErrUsernameTaken` → handler `409`.
8. On success, service `TokenService.Issue(userID)`.
9. Handler `201 { user_id, username, token }`.

**Login:**
1. Client `POST /auth/login {username, password}`.
2. Handler decodes; malformed/empty → `400`.
3. Service `GetUserByUsername`; not found → `ErrInvalidCredentials`.
4. Service `bcrypt.CompareHashAndPassword`; mismatch → `ErrInvalidCredentials`.
5. Both failure paths → handler `401 {"error":"invalid credentials"}` (indistinguishable).
6. Success → `Issue(userID)` → `200 { token }`.

**Protected `/me` via middleware:**
1. Client `GET /me` with `Authorization: Bearer <jwt>`.
2. Middleware reads header; missing/no `Bearer` prefix → `401`.
3. `TokenService.Parse` (HS256 alg guard); bad sig / wrong alg / malformed → `401`.
4. `GetUserByID(sub)`; not found → `401` (AC20).
5. Inject `AuthedUser{id, username}` into context; call `/me` handler.
6. Handler reads context → `200 { user_id, username }` (no extra query).

## 6. AC → Design coverage matrix

| AC | Satisfied by | Where |
|---|---|---|
| AC1 | `goose up` applies both migrations cleanly | `migrations/00001`, `00002` |
| AC2 | Two migrations create all five tables | §3 |
| AC3 | Column-exact DDL, nullability per DESIGN.md | §3 DDL + nullability note |
| AC4 | `username TEXT NOT NULL UNIQUE` | migration 1 |
| AC5 | `PRIMARY KEY (match_id, zone)`, no surrogate | migration 2 |
| AC6 | Four `REFERENCES` clauses | migrations 1 & 2 |
| AC7 | Reverse-FK `-- +goose Down` drops | §3 down order |
| AC8 | Layered pkgs, no unused deps → build/vet/lint clean | whole layout |
| AC9 | `cmd/server` + `internal/{handler,service,store,model}` | §2.1 layout |
| AC10 | `pgx/v5` only; no ORM in go.mod | §2.1, go.mod deps |
| AC11 | `slog` JSON handler at startup; no fmt/log.Print | `main.go` slog setup |
| AC12 | `GET /health` → `200 {"status":"ok"}`, no DB probe | `handler/health.go` |
| AC13 | Signup: bcrypt hash persisted, `201 {user_id,username,token}` | `auth_service`, `handler/auth.go` |
| AC14 | 23505 → 409, tx rollback → no row in either table | `user_store`, `handler/auth.go` |
| AC15 | Login `200 {token}`; `sub`=uuid, no `exp` | `token_service.Issue` |
| AC16 | Unknown user & wrong pw → same `401 invalid credentials` | `auth_service.Login` |
| AC17 | HS256 sign + alg guard rejects other alg / wrong key | `token_service` |
| AC18 | `/me` `200 {user_id,username}` from context | `middleware`, `handler/me.go` |
| AC19 | Missing/malformed/bad-sig token → `401` | `middleware` |
| AC20 | Valid sig but unknown sub → `401` (DB resolve) | `middleware` step 4 |

## go.mod dependencies (no ORM)

- `github.com/jackc/pgx/v5` — Postgres driver + `pgxpool` (AC10). Brings `pgconn` for the 23505 `PgError` check.
- `github.com/golang-jwt/jwt/v5` — HS256 issue/verify with `WithValidMethods` alg guard (A-7).
- `golang.org/x/crypto/bcrypt` — password hashing, cost 12 (A-7).
- `github.com/google/uuid` — app-side `uuid.UUID` PKs (A-1).
- **Router:** none — Go 1.22+ stdlib `net/http.ServeMux` (A-6). Set `go 1.22` (or later) in `go.mod`.
- `goose` is a **CLI tool** run against `backend/migrations/`, not a library import (AC1). It is not added to `go.mod`.

## 7. Risks & Mitigations

- **Signup double-insert partial failure** → both inserts share one tx; rollback on any
  error keeps AC14 true across both tables.
- **JWT algorithm confusion / `alg:none`** → `TokenService.Parse` uses
  `WithValidMethods(["HS256"])` + HMAC method assertion in the keyfunc (AC17).
- **Account-existence leak on login** → single `ErrInvalidCredentials` for both unknown
  user and wrong password; identical `401` body (AC16). Note the minor timing side
  channel (no bcrypt compare when user is unknown) is accepted for a single-user app.
- **bcrypt 72-byte silent truncation** → explicit `> 72` byte rejection at `400`
  before hashing (OQ-4), so truncation is unreachable.
- **Boot with missing secret** → `config.Load()` fails on empty `JWT_SIGNING_KEY` /
  `DATABASE_URL`; `main` exits non-zero (FR-B7). No secret defaults in code.
- **Non-expiring token cannot be revoked** → accepted trade-off (spec §7); no
  revocation machinery this slice.

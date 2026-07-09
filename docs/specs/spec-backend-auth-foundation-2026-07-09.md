# Spec: Backend + Auth Foundation (Phase 1, Slice 1)

**Date:** 2026-07-09
**Phase:** Phase 1 (Skeleton)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Stand up the backend foundation for the Tennis Shot Tracker so all later Phase 1
work has a data path and an authenticated caller to build on. This slice delivers
three things and nothing more: the full PostgreSQL schema (all five tables from
DESIGN.md), a Go API server skeleton in the locked project layout, and
username/password authentication that issues a long-lived JWT wrapping the
`user_id`. It proves the auth and persistence spine end-to-end without any iOS,
CV, or gameplay business logic. Gameplay tables are created now (so migrations are
complete and stable) but their CRUD endpoints are deferred to later slices.

## 2. Scope

### In scope
- **Schema:** goose migrations under `backend/migrations/` creating all five tables
  (`user_login`, `profile`, `match`, `record`, `match_summary`) exactly as defined
  in DESIGN.md "Data model (PostgreSQL)", including UUID PKs, the composite PK on
  `match_summary (match_id, zone)`, and the stated FKs.
- **Server skeleton:** Go API server in the CLAUDE.md layout (`backend/cmd/`
  entrypoint; `internal/handler`, `internal/service`, `internal/store`,
  `internal/model`) using `pgx/v5` (no ORM), `slog` structured logging, and
  `uuid.UUID` primary keys.
- **Health endpoint:** `GET /health`.
- **Auth:** `POST /auth/signup` and `POST /auth/login`. Passwords hashed with
  bcrypt. Login issues a non-expiring JWT whose subject is the `user_id` (UUID).
- **Auth middleware:** validates the JWT, resolves `user_id`, and rejects
  missing/invalid tokens.
- **One minimal protected endpoint** `GET /me` — the smallest thing "auth itself
  needs" so the middleware is exercisable and testable (echoes the authenticated
  user). Without a protected route the middleware would be dead code and its
  acceptance criteria untestable.

### Out of scope (non-goals)
- **iOS shell / any Swift.** Deferred to a later Phase 1 slice.
- **CV pipeline / any Python.** Deferred (Phase 3).
- **CRUD endpoints for `match` / `record` / `match_summary`** beyond `GET /me`.
  Tables are created now; their business endpoints are deferred. Reason: this slice
  is the auth + persistence spine only; gameplay endpoints depend on decisions not
  yet needed.
- **The `match_summary` aggregation/rebuild routine.** Schema only this run; the
  end-of-match aggregation (DESIGN.md "When `match_summary` is built") is deferred.
- **Profile CRUD** (read/update display name, avatar). Table created; endpoints
  deferred. (See Open Question OQ-1 on whether signup seeds the profile row.)
- **Token revocation / logout server-side machinery.** Explicitly excluded per the
  accepted trade-off (§7, §8-note).

## 3. Acceptance Criteria

Each criterion is independently verifiable.

**Schema**
- [ ] AC1: `goose -dir backend/migrations postgres "$DATABASE_URL" up` applies
  cleanly against an empty PostgreSQL database with exit code 0.
- [ ] AC2: After migration, all five tables exist: `user_login`, `profile`,
  `match`, `record`, `match_summary`.
- [ ] AC3: Every column listed in §5 exists with the stated type and nullability;
  no columns are added beyond those in §5 except where §9 Assumptions explicitly
  justify them.
- [ ] AC4: `user_login.username` has a UNIQUE constraint; inserting two rows with
  the same username fails.
- [ ] AC5: `match_summary` has composite PRIMARY KEY `(match_id, zone)` and no
  surrogate id column.
- [ ] AC6: Declared foreign keys exist: `profile.user_id → user_login.user_id`,
  `match.user_id → user_login.user_id`, `record.match_id → match.match_id`,
  `match_summary.match_id → match.match_id`.
- [ ] AC7: `goose ... down` (one step per migration) reverses cleanly to an empty
  schema with exit code 0.

**Server skeleton**
- [ ] AC8: `go build ./...`, `go vet ./...`, and `golangci-lint run ./...` all pass
  from the `backend/` module.
- [ ] AC9: The server entrypoint lives under `backend/cmd/`; handler/service/store/
  model code lives under the matching `internal/` packages.
- [ ] AC10: DB access uses `pgx/v5`; no ORM dependency appears in `go.mod`.
- [ ] AC11: Logs are emitted via `slog` in structured form (key/value or JSON), not
  `fmt.Print`/`log.Print`.
- [ ] AC12: `GET /health` returns `200` with body `{"status":"ok"}` when the process
  is running. (See OQ-3 on whether it probes the DB.)

**Auth**
- [ ] AC13: `POST /auth/signup` with a new username creates one `user_login` row
  whose `password_hash` is a bcrypt hash (not the plaintext) and returns per the §6
  contract.
- [ ] AC14: `POST /auth/signup` with an already-taken username returns `409` and
  creates no new row.
- [ ] AC15: `POST /auth/login` with correct credentials returns `200` and a JWT
  string. Decoding the JWT yields `sub` = the user's `user_id` UUID and contains no
  `exp` claim.
- [ ] AC16: `POST /auth/login` with a wrong password OR unknown username returns
  `401` with an indistinguishable error body (no account-existence leak).
- [ ] AC17: The JWT is signed HS256 with the key from the configured env var
  (§7). A token signed with a different key is rejected by the middleware.
- [ ] AC18: `GET /me` with a valid `Authorization: Bearer <jwt>` returns `200` and
  the authenticated `user_id` (and `username`).
- [ ] AC19: `GET /me` with a missing, malformed, or bad-signature token returns
  `401`.
- [ ] AC20: `GET /me` with a well-formed, correctly-signed token whose `sub` is a
  UUID that no longer exists in `user_login` returns `401` (middleware resolves the
  user, not just the signature).

## 4. Functional Requirements

### Backend (Go)
- **FR-B1:** A single Go module rooted at `backend/go.mod`. Entrypoint package under
  `backend/cmd/` (e.g. `backend/cmd/server`).
- **FR-B2:** Layered packages: `internal/handler` (HTTP), `internal/service`
  (business logic: hashing, token issue/verify, user lookup), `internal/store`
  (pgx queries), `internal/model` (domain types). Handlers do not talk to the DB
  directly; they call services, which call stores.
- **FR-B3:** Postgres access via `pgx/v5` connection pool (`pgxpool`). No ORM.
- **FR-B4:** All domain PKs are `uuid.UUID`. (`match_summary` uses no surrogate PK —
  its identity is the composite `(match_id, zone)`.)
- **FR-B5:** Structured logging via `slog` throughout; the process configures one
  `slog` handler at startup.
- **FR-B6:** Errors are returned, never panicked, except truly unrecoverable startup
  failures (e.g. cannot read config, cannot connect to DB at boot).
- **FR-B7:** Config is read from environment variables at startup (§7). Missing
  required vars cause the process to fail loudly on boot, not at first request.
- **FR-B8:** `GET /health` — liveness endpoint (§6).
- **FR-B9:** `GET /me` — protected endpoint guarded by the auth middleware (§6),
  included solely to exercise the middleware this slice.

### Auth (Go)
- **FR-A1:** `POST /auth/signup` — hash the submitted password with bcrypt and
  insert a `user_login` row. Reject duplicate usernames.
- **FR-A2:** `POST /auth/login` — look up the user by username, compare the password
  against the stored bcrypt hash, and on success issue a JWT.
- **FR-A3:** JWT is HS256, subject (`sub`) = `user_id` UUID string, **no `exp`
  claim** (non-expiring, per DESIGN.md Auth). Signing key from env (§7).
- **FR-A4:** Auth middleware reads `Authorization: Bearer <token>`, verifies the
  HS256 signature with the configured key, extracts `sub`, resolves the matching
  `user_login` row, and places the resolved `user_id` into the request context for
  downstream handlers. The middleware resolves the row (not just the signature)
  because `GET /me` must return `username` while the JWT carries only `user_id`;
  this DB read is a consequence of that contract, not extra hardening. Any failure
  (missing header, malformed token, bad signature, unknown/deleted user) results in
  `401`.

### iOS (Swift)
- N/A for this slice (explicit non-goal).

### CV Pipeline (Python)
- N/A for this slice (explicit non-goal).

## 5. Data Model

Restated at column level, copied faithfully from DESIGN.md "Data model
(PostgreSQL)". Nullability is exactly as DESIGN.md states it: only columns DESIGN.md
marks `(nullable)` are nullable; columns DESIGN.md marks `NOT NULL` are NOT NULL.
DESIGN.md is silent on defaults, timestamp NOT NULL-ness, UUID generation, and FK
`ON DELETE` behavior — those genuinely-underspecified points are listed in §8 (Open
Questions) and §9 (Assumptions) rather than silently baked into the columns below.

### `user_login`
| Column | Type | Constraints |
|---|---|---|
| `user_id` | UUID | PRIMARY KEY |
| `username` | TEXT | UNIQUE, NOT NULL |
| `password_hash` | TEXT | NOT NULL (bcrypt) |
| `created_at` | TIMESTAMPTZ | (see §9 A-3) |

### `profile` (1:1 with `user_login`)
| Column | Type | Constraints |
|---|---|---|
| `user_id` | UUID | PRIMARY KEY, FK → `user_login.user_id` |
| `display_name` | TEXT | |
| `avatar_url` | TEXT | nullable |
| `updated_at` | TIMESTAMPTZ | |

### `match` (one session / match)
| Column | Type | Constraints |
|---|---|---|
| `match_id` | UUID | PRIMARY KEY |
| `user_id` | UUID | FK → `user_login.user_id` |
| `location` | TEXT | |
| `court_surface` | TEXT | `'hard' \| 'clay' \| 'grass' \| ...` |
| `played_at` | TIMESTAMPTZ | match datetime |
| `video_ref` | TEXT | nullable; local/remote reference |
| `ended_at` | TIMESTAMPTZ | nullable; set when session ends; triggers summary |
| `created_at` | TIMESTAMPTZ | |

### `record` (one detected shot within a match)
| Column | Type | Constraints |
|---|---|---|
| `record_id` | UUID | PRIMARY KEY |
| `match_id` | UUID | FK → `match.match_id` |
| `zone` | TEXT | taxonomy A; later B |
| `court_x` | REAL | nullable; homography court coords |
| `court_y` | REAL | nullable |
| `ts_ms` | INT | nullable; offset into the clip |
| `source` | TEXT | `'cv' \| 'manual'` — how the zone was set |
| `created_at` | TIMESTAMPTZ | |

### `match_summary` (per-zone counts; derived cache)
| Column | Type | Constraints |
|---|---|---|
| `match_id` | UUID | FK → `match.match_id`; part of PK |
| `zone` | TEXT | part of PK |
| `shot_count` | INT | |
| `computed_at` | TIMESTAMPTZ | |
| | | **PRIMARY KEY (`match_id`, `zone`)** |

**Source of truth vs. cache (DESIGN.md):** `record` is the source of truth (zone +
coords + timestamp per shot). `match_summary` is a derived, rebuildable cache
computed only from `record`; never hand-edited. The aggregation routine that
populates it is out of scope for this slice (schema only).

### Modified queries
None — this is the initial schema. Queries introduced this slice (all against
`user_login` only): insert on signup, select-by-username on login, select-by-id in
auth middleware.

## 6. API Contract

All request/response bodies are JSON (`Content-Type: application/json`).
Error responses use a uniform shape: `{"error": "<message>"}`.

### `GET /health`
- **Request:** none.
- **200 OK:** `{"status":"ok"}`
- **Errors:** see OQ-3 (whether it also probes the DB and can return `503`).

### `POST /auth/signup`
- **Request body:** `{ "username": string, "password": string }`
- **201 Created:** shape depends on OQ-2. Baseline (no auto-login):
  `{ "user_id": "<uuid>", "username": string }`.
- **400 Bad Request:** missing/empty `username` or `password`, or malformed JSON —
  `{"error":"..."}`.
- **409 Conflict:** username already taken — `{"error":"username already taken"}`.

### `POST /auth/login`
- **Request body:** `{ "username": string, "password": string }`
- **200 OK:** `{ "token": "<jwt>" }`
- **400 Bad Request:** missing/empty fields or malformed JSON.
- **401 Unauthorized:** wrong password OR unknown username — identical body
  `{"error":"invalid credentials"}` for both cases (no account-existence leak).

### `GET /me` (protected)
- **Headers:** `Authorization: Bearer <jwt>`
- **200 OK:** `{ "user_id": "<uuid>", "username": string }`
- **401 Unauthorized:** missing/malformed `Authorization` header, malformed token,
  bad signature, or `sub` UUID not found in `user_login` — `{"error":"unauthorized"}`.

**JWT transport convention:** `Authorization: Bearer <token>` header on all protected
routes. (The iOS Keychain storage described in DESIGN.md is a client concern, out of
scope here.)

## 7. Non-Functional Requirements

### Configuration / environment
No secrets in code and no `.env` committed (locked Universal convention). All config
from environment:

| Env var | Purpose | Required | Notes |
|---|---|---|---|
| `DATABASE_URL` | Postgres connection string for pgx and goose | yes | reuses the exact name already used in CLAUDE.md Build & Test |
| `JWT_SIGNING_KEY` | HS256 symmetric signing/verification key | yes | never committed; process fails to boot if unset or empty |
| `PORT` | HTTP listen port | no | default `8080` if unset |

### Security
- **Password hashing:** bcrypt with cost factor **12**. `password_hash` stores the
  full bcrypt string; plaintext is never persisted or logged.
- **JWT algorithm:** **HS256** (symmetric). Justification: a single backend service
  holds the one signing key from env; symmetric HS256 avoids keypair management that
  buys nothing for a single-service, single-key deployment. The middleware must
  reject any token whose `alg` is not HS256 (guard against `alg:none` and algorithm
  confusion).
- **JWT claims:** `sub` = `user_id` UUID string. **No `exp` claim** — this *is* the
  "session never expires until app deleted" requirement (DESIGN.md Auth). No other
  claims required this slice.
- **Signing key:** read once at startup from `JWT_SIGNING_KEY`; never logged.
- **Credential responses:** login failures do not distinguish "no such user" from
  "wrong password" (AC16).
- **Accepted trade-off (documented, per DESIGN.md Auth):** a non-expiring token
  cannot be revoked server-side without extra machinery (e.g. a token blocklist or
  per-user token version). This is acceptable for a single-user personal app.
  Revisit if the app goes multi-user or public. This slice deliberately does NOT
  build revocation machinery.

### Performance
No specific latency target this slice; single-user volume. (DESIGN.md notes a live
`GROUP BY` over one match is already instant at this scale.)

## 8. Open Questions

Called out explicitly for the human to resolve before Phase 1 coding rather than
assumed:

- **OQ-1 — Does signup create the 1:1 `profile` row?** The `profile` table has a
  1:1 FK to `user_login`. Options: (a) signup eagerly inserts a `profile` row (with
  what `display_name` — echo the username? empty?), or (b) the profile row is
  created lazily when profile CRUD lands in a later slice. Profile *endpoints* are
  out of scope either way; this question is only about whether the row exists after
  signup.
- **OQ-2 — Does signup return a token (auto-login), or just `201 + user_id`?**
  Baseline in §6 assumes signup returns `201 + {user_id, username}` and `login` is
  the sole token issuer. If auto-login is desired, signup would also return a
  `token` and AC13/§6 change accordingly.
- **OQ-3 — Should `/health` probe the database?** Options: (a) pure liveness (process
  up → always `200`), or (b) readiness that pings the DB and returns `503` when the
  pool is unreachable. §6/AC12 assume (a) unless overridden.
- **OQ-4 — Password policy / input validation.** Any minimum password length or
  username charset/length rules? None assumed beyond "non-empty" (§6 `400`). Bcrypt
  silently truncates input beyond 72 bytes — should signup reject longer passwords
  explicitly?

## 9. Assumptions

Where DESIGN.md is silent, these are the explicit assumptions this spec makes so the
architect/coder has no undocumented decisions. Any of these the human can override.

- **A-1 — UUID generation:** primary-key UUIDs are generated **application-side in Go**
  (`uuid.UUID`) per the CLAUDE.md convention "UUIDs for all primary keys
  (`uuid.UUID`)", not via a DB default. DDL therefore does not add
  `DEFAULT gen_random_uuid()`. (If DB-side generation is preferred, that is a
  one-line change flagged here.)
- **A-2 — FK `ON DELETE` behavior:** DESIGN.md does not specify cascade behavior.
  Since delete endpoints are out of scope this slice, migrations create FKs with the
  PostgreSQL default (`NO ACTION`). Cascade decisions are deferred to the slices that
  introduce deletion.
- **A-3 — Timestamp columns:** DESIGN.md lists `created_at`/`updated_at`/`computed_at`
  as `TIMESTAMPTZ` without stating NOT NULL or defaults. This slice only writes
  `user_login.created_at` (set to `now()` at insert time, from the app or a column
  default — architect's choice). Other timestamp columns belong to out-of-scope
  tables and are created as-declared; their write behavior is defined when their
  endpoints land.
- **A-4 — `zone` / `source` / `court_surface` are plain `TEXT`**, not DB enums or
  CHECK constraints. DESIGN.md shows the allowed values as comments/examples and
  notes the zone set is still "configurable" and "to be confirmed against a court
  diagram" (open item). Enforcing them as DB constraints now would prematurely lock
  an unconfirmed taxonomy; validation is deferred to the record-write slice.
- **A-5 — Migrations are split logically** (e.g. auth tables vs. gameplay tables) but
  all land in this slice; the exact file count is the architect's call. All five
  tables must exist after `up` (AC2).
- **A-6 — HTTP router / mux:** no specific framework mandated; standard library or a
  lightweight router is acceptable so long as the layout (FR-B2) and conventions
  hold. Router choice is an implementation decision, not a spec decision.
- **A-7 — bcrypt library:** `golang.org/x/crypto/bcrypt`. JWT library choice
  (e.g. `github.com/golang-jwt/jwt/v5`) is an implementation decision; the spec only
  fixes HS256 + claim shape + no-`exp`.

# Plan: Backend Gameplay CRUD (Phase 1, Slice 3)

**Spec:** `docs/specs/spec-backend-gameplay-crud-2026-07-09.md`
**Date:** 2026-07-09
**Author:** architect (AI)
**Scope:** Go backend only (no iOS, no CV). All nine OQs locked at their spec baselines.

## 1. Architecture Overview

This slice adds the authenticated gameplay data path on top of the shipped auth
slice, reusing its exact four-layer split (`model` → `store` → `service` →
`handler`) and its conventions (pgx/v5 on `*Store`, typed sentinel errors,
app-side `uuid.New()`, `writeJSON`/`writeError`, `RequireAuth` + `AuthedUser`
context, Go 1.22 method+pattern routing). Six new endpoints are added — create /
list / get / end match, add / list shots — plus a summary read. Ownership is
enforced *in the query* (`WHERE match_id = $1 AND user_id = $2`) so no cross-user
row is ever read into memory; a missing-or-unowned match maps to a byte-identical
`404 {"error":"match not found"}` (no existence leak, mirroring the auth slice's
login stance). Two mutations are transactional: batch shot insert (all-or-nothing)
and end-match (set `ended_at` + `rebuildSummary` in one tx). `rebuildSummary` is
the sole writer of `match_summary`, derived purely from `record`, and is exported
so its direct tests (AC19/AC19b) can drive it inside their own tx. Migration
`00003` adds one index on `record(match_id)`; no table or column changes.

## 2. Component Design

### 2.1 Backend (Go)

Module path: `github.com/SupanatSMOST/tennis-tracker/backend`.

#### New files

- **`internal/model/match.go`** — domain types `Match`, `Record`, `SummaryRow`.
  Nullable columns are Go pointers so "absent" round-trips as SQL NULL and JSON
  `null`. No JSON tags in model (wire DTOs live in handler, matching `model/user.go`).
- **`internal/store/match_store.go`** — match + summary queries on `*Store`:
  `CreateMatch`, `ListMatches`, `GetMatchOwned`, `EndMatch`, and the exported
  `RebuildSummary`. Sentinel errors `ErrMatchNotFound`, `ErrMatchAlreadyEnded`.
- **`internal/store/record_store.go`** — record queries on `*Store`:
  `InsertRecords` (batch, tx, ownership-guarded), `ListRecords`, `GetSummary`.
- **`internal/store/match_store_test.go`** — integration tests for match write/read/
  ownership/end (AC8/10/11/12, OQ-2, AC-Z1/Z2 at store level).
- **`internal/store/rebuild_summary_test.go`** — direct tests of `RebuildSummary`
  (AC17/AC18/AC19/AC19b) driving the exported routine inside a test-owned tx.
- **`internal/store/record_store_test.go`** — batch insert + list + ownership
  (AC14/AC16, cross-user isolation at store level).
- **`internal/service/gameplay_service.go`** — `GameplayService` with validation
  (`court_surface`, `source`, `zone`, `played_at` parse) and orchestration; owns
  `uuid.New()` id generation and reuses the auth slice's `ValidationError` type
  for 400 mapping.
- **`internal/service/gameplay_service_test.go`** — unit tests for validation
  branches (AC9 surface, AC15 batch-reject, source default OQ-7, zone-empty).
- **`internal/handler/gameplay.go`** — `GameplayHandler` struct, request/response
  DTOs, six handler methods, and status mapping (400/404/409/500).
- **`internal/handler/gameplay_e2e_test.go`** — full-router E2E: ownership 404
  parity (AC-Z1), no-write on cross-user (AC-Z2), 401 before ownership (AC-Z3),
  summary read (AC20), end→summary (AC12/AC17), batch (AC14/AC15).
- **`migrations/00003_gameplay_indexes.sql`** — the one index (§3 below).

#### Modified files

- **`internal/handler/router.go`** — `BuildRouter` gains a `*GameplayHandler`
  parameter and registers the six new routes, each wrapped in
  `RequireAuth(tokens, s)`. **Signature change ripples to two call sites** (see
  wiring task): `cmd/server/main.go` and the `e2eBuildServer` helper in
  `router_e2e_test.go`. Both must be updated in the same task or AC1 (build) and
  AC5 (auth tests unchanged / green) fail.
- **`cmd/server/main.go`** — construct `GameplayService` + `GameplayHandler` and
  pass the handler into `BuildRouter` (mirrors the existing auth wiring block).

#### Key types (model)

```go
// internal/model/match.go
type Match struct {
    MatchID      uuid.UUID
    UserID       uuid.UUID
    Location     *string     // nullable (OQ-9)
    CourtSurface string      // required, validated app-side
    PlayedAt     *time.Time  // nullable (OQ-9); RFC3339 on the wire
    EndedAt      *time.Time  // NULL until POST .../end
    CreatedAt    time.Time   // DB DEFAULT now()
    // VideoRef intentionally omitted — never read/written this slice (FR-B6).
}

type Record struct {
    RecordID  uuid.UUID
    MatchID   uuid.UUID
    Zone      string     // required non-empty; NOT taxonomy-validated (FR-V3)
    CourtX    *float32   // REAL, nullable (FR-V4)
    CourtY    *float32   // REAL, nullable (FR-V4)
    TsMs      *int32     // INTEGER, nullable (FR-V4)
    Source    string     // validated {cv,manual}; defaults 'manual' (OQ-7)
    CreatedAt time.Time  // DB DEFAULT now()
}

type SummaryRow struct {
    Zone       string
    ShotCount  int
    ComputedAt time.Time
}
```

#### Store method signatures + SQL

Sentinel errors (in `match_store.go`, package-level, mirroring `ErrUserNotFound`):

```go
var ErrMatchNotFound     = errors.New("match not found")
var ErrMatchAlreadyEnded = errors.New("match already ended")
```

**`CreateMatch(ctx, m model.Match) error`** — single insert; `created_at` defaults
in DB; `id` and `user_id` come from the service. `RETURNING created_at` populates
the caller's struct so the response carries the DB timestamp.

```sql
INSERT INTO match (match_id, user_id, location, court_surface, played_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING created_at
```

**`ListMatches(ctx, userID uuid.UUID) ([]model.Match, error)`** — caller-scoped,
newest first (FR-M2, OQ-5 no pagination). Returns empty slice (not nil-error) when
none.

```sql
SELECT match_id, user_id, location, court_surface, played_at, ended_at, created_at
FROM match WHERE user_id = $1 ORDER BY created_at DESC
```

**`GetMatchOwned(ctx, matchID, userID uuid.UUID) (model.Match, error)`** — the
ownership guard (FR-Z1/Z2). `pgx.ErrNoRows` → `ErrMatchNotFound` (unknown and
not-owned are indistinguishable). This is the pool-read guard used by get/list-
records/summary.

```sql
SELECT match_id, user_id, location, court_surface, played_at, ended_at, created_at
FROM match WHERE match_id = $1 AND user_id = $2
```

**`EndMatch(ctx, matchID, userID uuid.UUID) (model.Match, error)`** — single tx
(FR-M4, A-5). Ownership + already-ended cannot be told apart by an
`UPDATE ... WHERE ended_at IS NULL` returning 0 rows, so the tx **SELECTs the owned
row first** (`... WHERE match_id=$1 AND user_id=$2 FOR UPDATE`): no row →
`ErrMatchNotFound` (404); `ended_at` already set → `ErrMatchAlreadyEnded` (409,
OQ-2, `ended_at` immutable). Otherwise `UPDATE match SET ended_at = now() ...
RETURNING ...`, then `RebuildSummary(ctx, tx, matchID)` **in the same tx**, then
commit. Deferred `tx.Rollback` (no-op after commit), mirroring
`CreateUserWithProfile`.

**`RebuildSummary(ctx context.Context, tx pgx.Tx, matchID uuid.UUID) error`** —
**exported**, tx-typed, the sole writer of `match_summary` (FR-S1/S3). Signature is
fixed: `EndMatch` passes its live tx; the direct test opens its own tx. Two
statements, both run unconditionally (the delete must run even in the zero-shot
case — AC17 — and is exactly what AC19b exercises):

1. Upsert current zones (the exact spec query, AC18):
   ```sql
   INSERT INTO match_summary (match_id, zone, shot_count, computed_at)
   SELECT match_id, zone, COUNT(*), now()
   FROM record WHERE match_id = $1 GROUP BY match_id, zone
   ON CONFLICT (match_id, zone)
   DO UPDATE SET shot_count = EXCLUDED.shot_count, computed_at = EXCLUDED.computed_at
   ```
2. Delete stale zones no longer present in `record` (AC19b). Use `NOT EXISTS`
   (not `NOT IN`) — `record.zone` is nullable in `00002`, and `NOT IN` against a
   subquery that can yield NULL silently deletes nothing (SQL three-valued-logic
   trap):
   ```sql
   DELETE FROM match_summary ms
   WHERE ms.match_id = $1
     AND NOT EXISTS (
       SELECT 1 FROM record r WHERE r.match_id = $1 AND r.zone = ms.zone
     )
   ```
   Zero-shot match → step 1 inserts nothing, step 2 deletes all prior rows → empty
   summary (AC17). It never reads/trusts the existing summary — derived purely from
   `record`.

**`InsertRecords(ctx, matchID, userID uuid.UUID, recs []model.Record) error`**
(`record_store.go`) — ownership-guarded batch insert in one tx (FR-R1, A-5). The tx
first re-checks ownership *and* not-ended state via `SELECT ... FOR UPDATE`
(`ErrMatchNotFound` 404 / `ErrMatchAlreadyEnded` 409 per OQ-3, so a cross-user or
ended match writes nothing — AC-Z2). Then loops the pre-validated slice with
`tx.Exec` inserts (or `pgx.Batch`), `created_at` DB-default, each `record_id`
app-generated. Any error rolls the whole batch back. (Service validates all shots
*before* calling this, so a bad element never opens a tx — AC15.)

```sql
-- guard (inside tx, FOR UPDATE):
SELECT ended_at FROM match WHERE match_id = $1 AND user_id = $2 FOR UPDATE
-- per row:
INSERT INTO record (record_id, match_id, zone, court_x, court_y, ts_ms, source)
VALUES ($1, $2, $3, $4, $5, $6, $7)
```

**`ListRecords(ctx, matchID, userID uuid.UUID) ([]model.Record, error)`** — verifies
ownership via `GetMatchOwned` (404 on miss), then reads all shots for the match,
deterministic order `ts_ms NULLS LAST, created_at` (FR-R3). Backed by
`idx_record_match_id`.

```sql
SELECT record_id, match_id, zone, court_x, court_y, ts_ms, source, created_at
FROM record WHERE match_id = $1 ORDER BY ts_ms ASC NULLS LAST, created_at ASC
```

**`GetSummary(ctx, matchID, userID uuid.UUID) ([]model.SummaryRow, error)`** —
verifies ownership (404), then reads stored `match_summary` rows; never
live-computes (FR-S4, OQ-1: `[]` until end). Empty slice when none.

```sql
SELECT zone, shot_count, computed_at FROM match_summary
WHERE match_id = $1 ORDER BY zone ASC
```

**Ownership guard note.** `GetMatchOwned`, `EndMatch`, and `InsertRecords` all
resolve the match with `WHERE match_id=$1 AND user_id=$2`; read paths (`get`,
`list-records`, `summary`) call `GetMatchOwned` first and return its
`ErrMatchNotFound` unchanged, so every ownership-checked route emits the identical
404 body (AC-Z1). Mutation guards live *inside* the tx (FR-Z2), so there is no
window where a cross-user row is read then written.

#### Service method responsibilities (`GameplayService`)

`GameplayService` holds `*store.Store`, constructed `NewGameplayService(s)`.
Validation happens here and returns `service.ValidationError` (reused from the auth
slice) → handler maps to 400.

- **`CreateMatch(ctx, userID, courtSurface string, location *string, playedAt *time.Time) (model.Match, error)`**
  — validate `court_surface ∈ {hard,clay,grass}` (FR-V1, AC9) else `ValidationError`;
  build `Match{MatchID: uuid.New(), UserID, ...}`; call `store.CreateMatch`.
  (RFC3339 parse of `played_at` happens in the handler DTO layer, since a parse
  failure is a 400 tied to the raw string — see §handler.)
- **`ListMatches(ctx, userID) ([]model.Match, error)`** — passthrough.
- **`GetMatch(ctx, matchID, userID) (model.Match, error)`** — passthrough
  (`ErrMatchNotFound` propagates).
- **`ListRecords(ctx, matchID, userID) ([]model.Record, error)`** — passthrough to
  `store.ListRecords` (`ErrMatchNotFound` propagates).
- **`EndMatch(ctx, matchID, userID) (model.Match, error)`** — passthrough
  (`ErrMatchNotFound` / `ErrMatchAlreadyEnded` propagate; the tx + `RebuildSummary`
  live in the store).
- **`AddRecords(ctx, matchID, userID uuid.UUID, shots []ShotInput) ([]uuid.UUID, error)`**
  — the validation gate (all-or-nothing, AC15): reject empty batch, any empty
  `zone` (FR-V3/V5), any `source ∉ {cv,manual}` (FR-V2) → `ValidationError`;
  default omitted `source` to `'manual'` (OQ-7). All validation completes **before**
  any store/tx call. On success generate a `record_id` per shot, build
  `[]model.Record`, call `store.InsertRecords`, return the generated ids.
- **`GetSummary(ctx, matchID, userID) ([]model.SummaryRow, error)`** — passthrough.

`ShotInput` is a small service-layer struct (zone + optional pointers + optional
source) so the handler DTO maps cleanly onto it without leaking `json` tags into
the service.

#### Handler DTOs + status mapping (`GameplayHandler`)

`GameplayHandler` holds `*service.GameplayService`, constructed
`NewGameplayHandler(gs)`. All UUIDs serialize as strings via `.String()` (FR-B5);
nullable fields are pointers serialized as `null` (A-7). (Handlers hold the
concrete `*service.GameplayService`, matching the auth pattern — there is no
interface to fake, so handler tests use the `DATABASE_URL`-gated path like the auth
handler tests.)

Shared response DTO (reused by create/get/list/end — one shape):

```go
type matchResponse struct {
    MatchID      string     `json:"match_id"`
    Location     *string    `json:"location"`
    CourtSurface string     `json:"court_surface"`
    PlayedAt     *time.Time `json:"played_at"`   // RFC3339 or null
    EndedAt      *time.Time `json:"ended_at"`     // null until ended
    CreatedAt    time.Time  `json:"created_at"`
    // no video_ref (FR-B6)
}
```

Request/response DTOs:
- `createMatchRequest{ CourtSurface string; Location *string; PlayedAt *string }`
  — `played_at` decoded as raw string then `time.Parse(time.RFC3339, ...)`;
  unparseable → 400 (FR-M1).
- `addRecordsRequest{ Shots []shotDTO }` where
  `shotDTO{ Zone string; CourtX *float32; CourtY *float32; TsMs *int32; Source *string }`
  — canonical `{"shots":[...]}` only (OQ-6); single = one-element array.
- `addRecordsResponse{ Created int; RecordIDs []string }` (§6 shape).
- `recordResponse{ RecordID string; Zone string; CourtX *float32; CourtY *float32;
  TsMs *int32; Source string; CreatedAt time.Time }` — the `GET .../records` list
  element (RecordID via `.String()`; nullable numbers serialize as `null`).
- summary rows → `[]summaryRow{ Zone string; ShotCount int; ComputedAt time.Time }`.

Handler status mapping (uniform `{"error":"..."}` via `writeError`):

| Condition | Status |
|---|---|
| malformed JSON / missing `court_surface` / bad `played_at` / empty batch / empty zone | 400 |
| `service.ValidationError` (bad surface, bad source, empty zone/batch) | 400 |
| `store.ErrMatchNotFound` (unknown **or** not-owned) | 404 `{"error":"match not found"}` |
| `store.ErrMatchAlreadyEnded` (OQ-2 end, OQ-3 records-after-end) | 409 |
| unexpected DB error (log via `slog.ErrorContext`) | 500 |
| success | 201 create / 201 add-records / 200 others |

The seven handlers (`CreateMatch`, `ListMatches`, `GetMatch`, `EndMatch`,
`AddRecords`, `ListRecords`, `GetSummary`) read `userFromContext` (defensive 401
guard as in `me.go`), decode
+ validate the DTO, call the service, and map errors with a `switch` +
`errors.Is`/`errors.As` exactly like `auth.go`. Missing/invalid token is handled by
`RequireAuth` before any handler runs (AC-Z3).

### 2.2 iOS (Swift)

**N/A** — explicit non-goal for this slice.

### 2.3 CV Pipeline (Python)

**N/A** — explicit non-goal for this slice.

## 3. Data Model Changes

**No table or column changes.** `match`, `record`, `match_summary` from
`00002_gameplay_tables.sql` are reused verbatim. One new migration adds a single
index (OQ-8 = yes; §5 of spec).

Migration filename: `backend/migrations/00003_gameplay_indexes.sql`

```sql
-- +goose Up
CREATE INDEX idx_record_match_id ON record (match_id);

-- +goose Down
DROP INDEX idx_record_match_id;
```

Backs the two hottest gameplay queries (`ListRecords` filter and the
`RebuildSummary` aggregation, both `WHERE match_id = $1`). Changes no column, type,
nullability, PK, or FK, so it cannot affect the Slice 1 schema ACs (AC7). `down`
drops only this index, leaving `00002` tables intact (AC6).

## 4. API Contract

All routes require `Authorization: Bearer <jwt>`; missing/invalid → 401 before any
other processing (AC-Z3). Bodies are JSON; errors are `{"error":"<msg>"}`; all
UUIDs are JSON strings.

### `POST /matches`
- **Request:** `{ "court_surface": "hard"|"clay"|"grass", "location"?: string, "played_at"?: string(RFC3339) }`
- **201:** `matchResponse` (`ended_at`: null).
- **400:** malformed JSON, missing/invalid `court_surface`, unparseable `played_at`.

### `GET /matches`
- **200:** `[matchResponse, ...]` caller-owned, newest first; `[]` if none.

### `GET /matches/{id}`
- **200:** `matchResponse`. **404:** unknown or not-owned (`{"error":"match not found"}`).

### `POST /matches/{id}/end`
- **Request:** none/empty. **200:** `matchResponse` with `ended_at` non-null.
- **404:** unknown/not-owned. **409:** already ended (OQ-2, `ended_at` immutable).

### `POST /matches/{id}/records`
- **Request:** `{ "shots": [ { "zone": string, "court_x"?: number, "court_y"?: number, "ts_ms"?: integer, "source"?: "cv"|"manual" }, ... ] }`
- **201:** `{ "created": integer, "record_ids": [string, ...] }`.
- **400:** malformed JSON, empty `shots`, any empty `zone`, any bad `source` (nothing inserted).
- **404:** unknown/not-owned. **409:** match already ended (OQ-3 baseline).

### `GET /matches/{id}/records`
- **200:** `[ { "record_id": string, "zone": string, "court_x": number|null, "court_y": number|null, "ts_ms": integer|null, "source": string, "created_at": string }, ... ]`, deterministic order.
- **404:** unknown/not-owned.

### `GET /matches/{id}/summary`
- **200:** `[ { "zone": string, "shot_count": integer, "computed_at": string }, ... ]` (stored rows; `[]` before end, OQ-1; never live-computed).
- **404:** unknown/not-owned.

No `403` anywhere (§7 of spec): 404 for not-owned prevents existence leak.

## 5. Sequence Diagrams (text)

### End match + summary (single tx, FR-M4/FR-S1)
1. `POST /matches/{id}/end` → `RequireAuth` resolves `AuthedUser` (401 on failure).
2. Handler → `GameplayService.EndMatch(ctx, matchID, userID)`.
3. Store `EndMatch`: `tx = pool.Begin`; `defer tx.Rollback`.
4. `SELECT ... WHERE match_id=$1 AND user_id=$2 FOR UPDATE`:
   - no row → return `ErrMatchNotFound` (→ 404).
   - `ended_at` set → return `ErrMatchAlreadyEnded` (→ 409).
5. `UPDATE match SET ended_at = now() ... RETURNING ...`.
6. `RebuildSummary(ctx, tx, matchID)` — upsert current zones, delete stale zones.
7. `tx.Commit`. Handler → 200 `matchResponse`.

### Batch add shots (validate-then-tx, FR-R1/AC15)
1. `POST /matches/{id}/records` → `RequireAuth` (401 on failure).
2. Handler decodes `{"shots":[...]}`; empty/malformed → 400 without touching service.
3. `GameplayService.AddRecords`: validate **every** shot (zone non-empty, source ∈
   {cv,manual}, default 'manual'); any failure → `ValidationError` (→ 400), no tx.
4. Generate `record_id` per shot; `store.InsertRecords(ctx, matchID, userID, recs)`.
5. Store: `tx = pool.Begin`; `SELECT ... FOR UPDATE` ownership+ended guard
   (404 / 409); loop inserts; commit (or rollback on any error → zero rows).
6. Handler → 201 `{created, record_ids}`.

### Ownership 404 parity (AC-Z1)
Every `{id}` route resolves via `WHERE match_id=$1 AND user_id=$2`. Unknown id and
another user's id both yield `ErrMatchNotFound` → identical `404 {"error":"match
not found"}` — indistinguishable.

## 6. Risks & Mitigations

- **`BuildRouter` signature change breaks two call sites.** Adding the gameplay
  handler param breaks `cmd/server/main.go` and `e2eBuildServer` in
  `router_e2e_test.go`. *Mitigation:* update both in the wiring task; keep the param
  additive; verify `go build ./...` (AC1) and the auth E2E suite (AC5) after wiring.
- **0-row UPDATE ambiguity (404 vs 409).** A blind `UPDATE ... WHERE ended_at IS
  NULL` cannot separate not-owned from already-ended. *Mitigation:* SELECT-then-
  branch inside the tx (both `EndMatch` and `InsertRecords`).
- **Stale-zone rows survive rebuild.** An upsert-only rebuild leaves orphan zones
  (AC19b). *Mitigation:* the unconditional `DELETE ... zone NOT IN (...)` step,
  which also yields the empty summary for zero-shot matches (AC17).
- **`RebuildSummary` unreachable from external `_test` package.** Auth tests use
  `package store_test`. *Mitigation:* export `RebuildSummary` with the fixed
  `(ctx, tx, matchID)` signature so AC19/AC19b drive it directly in a test-owned tx.
- **Cross-user write window.** Fetch-then-compare in Go could read another user's
  row. *Mitigation:* guard is in the SQL predicate and runs inside the mutation tx
  (FR-Z2), so nothing is read-then-written across users (AC-Z2).
- **CI regression.** New tests must `t.Skip` when `DATABASE_URL` is unset and must
  not self-migrate (goose runs in CI before tests). *Mitigation:* reuse the auth
  harness helpers verbatim; per-test unique data + `t.Cleanup` row deletion in FK
  order (`match_summary` → `record` → `match`).

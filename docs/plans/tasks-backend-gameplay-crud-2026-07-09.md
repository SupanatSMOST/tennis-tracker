# Tasks: Backend Gameplay CRUD (Phase 1, Slice 3)

**Plan:** `docs/plans/plan-backend-gameplay-crud-2026-07-09.md`
**Total tasks:** 10

Ordering is bottom-up so `go build ./...` and `go test ./...` stay green
incrementally: migration → model → store (match, records, rebuild, end) → service
→ handler → wiring → E2E. Migration and application code are never combined in one
task. All integration tests reuse the auth harness: real pool from
`DATABASE_URL`, `t.Skip` when unset, per-test unique data, `t.Cleanup` row deletion
in FK order (`match_summary` → `record` → `match`), and tests do **not** self-migrate.

---

## Task 1: Migration 00003 — `record(match_id)` index
**Layer:** migration
**Files to create/modify:**
- `backend/migrations/00003_gameplay_indexes.sql` — goose Up creates
  `idx_record_match_id ON record (match_id)`; goose Down drops only that index.
**Depends on:** none
**Acceptance:** `goose ... up` applies `00003` cleanly on top of `00001`/`00002`;
`goose ... down` one step drops only the index and leaves `00002` tables intact.
No column/type/nullability/PK/FK change. (AC6, AC7)
**Test:** Extend `migrations/schema_test.go` with a test asserting the index exists
after `up` (query `pg_indexes` / `pg_class` for `idx_record_match_id` on `record`)
and that all `00002` columns/PK/FKs are unchanged (spot-check via existing helpers).
`t.Skip` when `DATABASE_URL` unset; no self-migration.

---

## Task 2: Model types + store sentinel errors
**Layer:** backend
**Files to create/modify:**
- `backend/internal/model/match.go` — `Match`, `Record`, `SummaryRow` structs with
  nullable columns as pointers (`*string`, `*time.Time`, `*float32`, `*int32`), no
  JSON tags (mirror `model/user.go`). `Match` omits `VideoRef` entirely (FR-B6).
- `backend/internal/store/match_store.go` — declare package-level sentinels
  `ErrMatchNotFound` and `ErrMatchAlreadyEnded` (only the vars + doc comments this
  task; methods land in later tasks). Mirror `ErrUserNotFound` style.
**Depends on:** none
**Acceptance:** `go build ./...` and `go vet ./...` pass; the two sentinels and
three model types compile and are exported. (supports AC1/AC2)
**Test:** No dedicated test — covered transitively by later store tests. Ensure the
package still builds (the coder confirms `go build ./...`).

---

## Task 3: Store — match write/read + ownership guard
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/match_store.go` — add `CreateMatch(ctx, m) error`
  (INSERT ... RETURNING created_at), `ListMatches(ctx, userID) ([]Match, error)`
  (WHERE user_id, ORDER BY created_at DESC, empty slice when none),
  `GetMatchOwned(ctx, matchID, userID) (Match, error)`
  (WHERE match_id=$1 AND user_id=$2; `pgx.ErrNoRows` → `ErrMatchNotFound`).
- `backend/internal/store/match_store_test.go` — create the shared gameplay test
  helpers here (`buildPool` reuse pattern, `uniqueUsername`, a `seedUser` helper,
  and `cleanupMatch`/`cleanupUser` deleting in FK order).
**Depends on:** Task 2
**Acceptance:** create inserts exactly one owned `match` row and returns its
`created_at`; list returns only the caller's rows newest-first; get returns the
owned row and `ErrMatchNotFound` for both unknown id and another user's id.
(AC8, AC10, AC11; store-level AC-Z1)
**Test:** Integration: create→get round-trip (fields intact, `ended_at` nil,
nullable location/played_at round-trip as NULL and as value); list isolation (user
A never sees user B); get returns `ErrMatchNotFound` for unknown and for
cross-user. `t.Cleanup` in FK order; no self-migration.

---

## Task 4: Store — record batch insert + list
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/record_store.go` — `InsertRecords(ctx, matchID, userID,
  recs) error` (tx: `SELECT ended_at ... WHERE match_id=$1 AND user_id=$2 FOR
  UPDATE` guard → `ErrMatchNotFound`/`ErrMatchAlreadyEnded`; loop inserts;
  all-or-nothing rollback) and `ListRecords(ctx, matchID, userID) ([]Record,
  error)` (ownership via `GetMatchOwned`, then SELECT ORDER BY ts_ms NULLS LAST,
  created_at).
- `backend/internal/store/record_store_test.go` — batch + list integration tests.
**Depends on:** Task 3 (reuses `GetMatchOwned` + helpers)
**Acceptance:** N-element batch inserts exactly N rows in one tx; a forced error
(e.g. cross-user match) inserts zero rows; list returns all shots for the match in
deterministic order and none from another match; cross-user list/insert →
`ErrMatchNotFound`. (AC14, AC16; store-level AC-Z2)
**Test:** Integration: insert N then list returns N; insert against another user's
match returns `ErrMatchNotFound` and writes zero rows; nullable court_x/court_y/
ts_ms round-trip as NULL and as value; order assertion (ts_ms NULLS LAST).

---

## Task 5: Store — `RebuildSummary` (exported) + direct tests
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/match_store.go` — add exported
  `RebuildSummary(ctx context.Context, tx pgx.Tx, matchID uuid.UUID) error`:
  (1) upsert current zones with the exact spec query
  `SELECT zone, COUNT(*) ... GROUP BY zone` + `ON CONFLICT (match_id, zone) DO
  UPDATE`; (2) **unconditionally** delete stale zones with `NOT EXISTS` (NOT
  `NOT IN` — `record.zone` is nullable, and `NOT IN` over a NULL-yielding subquery
  deletes nothing): `DELETE FROM match_summary ms WHERE ms.match_id=$1 AND NOT
  EXISTS (SELECT 1 FROM record r WHERE r.match_id=$1 AND r.zone=ms.zone)`. Never
  reads the existing summary. Fixed signature — takes a `pgx.Tx`.
- `backend/internal/store/rebuild_summary_test.go` — direct tests driving
  `RebuildSummary` inside a **test-owned** tx (begin → seed record rows → call →
  assert → commit/rollback + cleanup).
**Depends on:** Task 3, Task 4 (needs match + record rows to aggregate)
**Acceptance:** after rebuild, `match_summary` has one row per distinct zone with
correct `COUNT(*)` and non-null `computed_at`; zero-shot match → zero summary rows;
re-running after inserting more shots overwrites counts (no duplicate
`(match_id, zone)`) and refreshes `computed_at`; deleting all rows of one zone then
re-running removes that zone's summary row while others are unaffected.
(AC17, AC18, AC19, AC19b)
**Test:** Direct routine tests in `package store_test`: happy aggregation (AC17/18);
rebuild-after-insert overwrites, no dupes (AC19); stale-zone removal after
in-test `DELETE FROM record WHERE zone=...` (AC19b); zero-shot yields `[]`.

---

## Task 6: Store — `EndMatch` (tx: guard → ended_at → RebuildSummary)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/store/match_store.go` — add `EndMatch(ctx, matchID, userID)
  (Match, error)`: single tx; `SELECT ... WHERE match_id=$1 AND user_id=$2 FOR
  UPDATE` (no row → `ErrMatchNotFound`; `ended_at` set → `ErrMatchAlreadyEnded`);
  `UPDATE ... SET ended_at = now() RETURNING ...`; call `RebuildSummary(ctx, tx,
  matchID)`; commit. Deferred rollback.
- `backend/internal/store/match_store_test.go` — end-match integration tests.
**Depends on:** Task 5 (calls `RebuildSummary`)
**Acceptance:** end on an owned, not-yet-ended match sets a non-null `ended_at`,
populates `match_summary` in the same tx, returns the updated match; end on an
already-ended match returns `ErrMatchAlreadyEnded` and does not change `ended_at`;
end on unknown/cross-user match returns `ErrMatchNotFound`. (AC12, OQ-2)
**Test:** Integration: create→add shots→end→assert `ended_at` non-null and summary
rows match shot zones; second end → `ErrMatchAlreadyEnded`, `ended_at` unchanged;
cross-user end → `ErrMatchNotFound`, target unchanged (AC-Z2).

---

## Task 7: Service — `GameplayService` (validation + orchestration)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/service/gameplay_service.go` — `GameplayService` +
  `NewGameplayService(*store.Store)`; a `ShotInput` struct; methods `CreateMatch`
  (validate `court_surface ∈ {hard,clay,grass}` → reuse `ValidationError`; generate
  `uuid.New()`), `ListMatches`, `GetMatch`, `ListRecords`, `EndMatch`
  (passthroughs), `AddRecords` (validate empty batch / empty zone / bad source,
  default source 'manual', **all before any store call**; generate `record_id` per
  shot; return ids), `GetSummary`.
- `backend/internal/service/gameplay_service_test.go` — validation unit tests (may
  use a thin store or `DATABASE_URL`-gated integration; validation branches need no
  DB and must run without one).
**Depends on:** Task 3, Task 4, Task 6 (calls those store methods)
**Acceptance:** invalid `court_surface` → `ValidationError` (no store call); empty
batch / any empty zone / any bad source → `ValidationError` (no store call, nothing
inserted); omitted source defaults to `'manual'`; valid inputs delegate to store
and return generated ids. (AC9, AC15, OQ-7)
**Test:** Unit (no DB): table-driven validation for surface, source (incl. default),
empty zone, empty batch — assert `ValidationError` and that the store is not invoked
on the failure paths.

---

## Task 8: Handler — `GameplayHandler` (DTOs + seven handlers + status mapping)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/gameplay.go` — `GameplayHandler` +
  `NewGameplayHandler(*service.GameplayService)`; request/response DTOs
  (`createMatchRequest` with `played_at` RFC3339 parse → 400 on failure,
  `matchResponse` shared across create/get/list/end with UUIDs as `.String()` and
  nullable pointers, `addRecordsRequest{Shots []shotDTO}`, `addRecordsResponse`,
  `recordResponse` for the `GET .../records` list element (record_id via
  `.String()`, court_x/court_y/ts_ms nullable, source, created_at — §4 shape),
  summary row DTO); seven handler methods (`CreateMatch`, `ListMatches`,
  `GetMatch`, `EndMatch`, `AddRecords`, `ListRecords`, `GetSummary`) reading
  `userFromContext` and mapping
  errors via `switch`/`errors.Is`/`errors.As` to 400/404/409/500, using
  `writeJSON`/`writeError`. `{id}` read via `r.PathValue("id")` + `uuid.Parse`
  (unparseable id → 404 `match not found`, so it is indistinguishable).
**Depends on:** Task 7
**Acceptance:** each handler compiles and maps: `ValidationError`/bad JSON/bad
`played_at`/empty batch → 400; `ErrMatchNotFound` → 404 `{"error":"match not
found"}`; `ErrMatchAlreadyEnded` → 409; unexpected → 500 (logged via
`slog.ErrorContext`); success codes 201/201/200. UUIDs serialized as strings,
nullable fields as `null`. (AC8/9/11/13/20 mapping; FR-B5; §6 contract)
**Test:** Handler-level tests where practical. Handlers hold the concrete
`*service.GameplayService` (auth pattern — no interface to fake), so use the
`DATABASE_URL`-gated path like the auth handler tests rather than building a mock.
Full HTTP behaviour is covered by the E2E task; keep this task's tests focused on
DTO decode + status mapping.

---

## Task 9: Wiring — `BuildRouter` + `main.go` (+ fix E2E helper)
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/router.go` — add a `*GameplayHandler` parameter to
  `BuildRouter`; register the six routes wrapped in `RequireAuth(tokens, s)`:
  `POST /matches`, `GET /matches`, `GET /matches/{id}`, `POST /matches/{id}/end`,
  `POST /matches/{id}/records`, `GET /matches/{id}/records`, `GET
  /matches/{id}/summary`.
- `backend/cmd/server/main.go` — construct `GameplayService` + `GameplayHandler`
  and pass into `BuildRouter` (mirror the auth wiring block).
- `backend/internal/handler/router_e2e_test.go` — update the `e2eBuildServer`
  helper to construct the gameplay handler and pass it into the now-changed
  `BuildRouter` signature. **Required** or AC1/AC5 fail.
**Depends on:** Task 8
**Acceptance:** `go build ./...` passes; the existing auth E2E suite still passes
unchanged (no regression); all six gameplay routes are reachable behind
`RequireAuth`. (AC1, AC5, AC-Z3 wiring)
**Test:** No new test file here beyond the helper edit; the existing auth E2E tests
must remain green, proving the signature change did not break wiring.

---

## Task 10: E2E — gameplay HTTP flow + ownership isolation
**Layer:** backend
**Files to create/modify:**
- `backend/internal/handler/gameplay_e2e_test.go` — full-router E2E (real pool →
  Store → services → handlers → `BuildRouter` → `httptest.NewServer`), reusing the
  auth E2E helpers (`e2eBuildServer`, `e2ePost`, `e2eGet`, unique data, cleanup).
  Two distinct signed-up users to exercise cross-user isolation.
**Depends on:** Task 9
**Acceptance:** end-to-end: signup→create match (201)→get→list; bad surface → 400,
no row (AC9); single + N-batch add (201) then list returns N (AC13/AC14); bad
batch (empty zone / bad source / empty array) → 400, zero rows (AC15);
end→summary populated (AC12/AC17), summary `[]` before end (AC20); for a second
user's match every `{id}` route returns byte-identical 404 `{"error":"match not
found"}` matching a nonexistent id, and cross-user mutations write nothing
(AC-Z1/AC-Z2); missing/invalid token → 401 before ownership (AC-Z3).
**Test:** This task *is* the E2E test. `t.Skip` when `DATABASE_URL` unset; per-test
unique users; `t.Cleanup` deletes `match_summary`→`record`→`match`→`profile`→
`user_login` in FK order for both users.

---

## AC coverage map

| AC | Task(s) |
|---|---|
| AC1 build | 2, 9 (all compile) |
| AC2 vet | all |
| AC3 lint | all |
| AC4 test green | 3–10 |
| AC5 CI unchanged | 9 |
| AC6/AC7 migration | 1 |
| AC8 create | 3, 8, 10 |
| AC9 bad surface 400 | 7, 8, 10 |
| AC10 list isolation | 3, 10 |
| AC11 get owned | 3, 8, 10 |
| AC12 end + summary | 6, 10 |
| AC13 single insert | 4, 8, 10 |
| AC14 batch insert | 4, 8, 10 |
| AC15 batch reject | 7, 10 |
| AC16 list records | 4, 7, 8, 10 |
| AC17 summary rows | 5, 6, 10 |
| AC18 exact query | 5 |
| AC19 rebuild overwrite | 5 |
| AC19b stale-zone removal | 5 |
| AC20 summary read | 8, 10 |
| AC-Z1 404 parity | 3, 8, 10 |
| AC-Z2 no cross-user write | 4, 6, 10 |
| AC-Z3 401 before ownership | 9, 10 |

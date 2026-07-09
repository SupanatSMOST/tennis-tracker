# Spec: Backend Gameplay CRUD (Phase 1, Slice 3)

**Date:** 2026-07-09
**Phase:** Phase 1 (Skeleton)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Deliver the authenticated data path that stores a session's shots and reads them
back, so Phase 1 has a working end-to-end gameplay backend without any CV, video,
or iOS. This slice builds CRUD over the three gameplay tables already created in
migration `00002_gameplay_tables.sql` (`match`, `record`, `match_summary`): create
and list matches, end a match, add shots (single and batch), list shots, and read
the derived per-zone summary. Every shot row is capture-method-agnostic — it
carries `zone` plus optional `court_x`/`court_y`/`ts_ms` and a `source`
(`'cv'|'manual'`) — so the same schema serves auto-CV (Phase 3) and manual tapping
(Phase 1) alike. All endpoints sit behind the existing JWT auth middleware
(`RequireAuth`) and are scoped to the authenticated `user_id`: a caller can only
see or modify their own matches and the shots within them.

## 2. Scope

### In scope

- **Match lifecycle endpoints** (all behind `RequireAuth`, scoped to caller):
  - Create a match (`location`, `court_surface`, `played_at`).
  - List the caller's matches.
  - Get one match by id (caller-owned only).
  - End a match — set `match.ended_at` and compute the summary in the same
    transaction.
- **Shot (`record`) endpoints:**
  - Add shots to a match — **batch insert** (array of shots, all-or-nothing in one
    transaction) and **single insert** served by the same endpoint.
  - List shots for a caller-owned match.
- **Summary (`match_summary`):**
  - The end-of-match aggregation routine (DESIGN.md "When `match_summary` is
    built"): `SELECT zone, COUNT(*) FROM record WHERE match_id = ? GROUP BY zone`,
    upserted into `match_summary` with `computed_at = now()`.
  - Exposed as one idempotent internal routine (`rebuildSummary(matchID)`) so any
    in-scope mutation that changes a match's shots can re-run the exact same logic
    (§4 FR-S1). In-scope triggers are enumerated in §4 and gated by OQ-2/OQ-3.
  - A read endpoint for the summary of a caller-owned match.
- **Ownership isolation** applied uniformly across every gameplay route (§4 FR-Z1,
  §6, AC-Z*).
- **Validation** of `court_surface` and `source` at the service layer (§4 FR-V*),
  returning `400`. `zone` stays unvalidated flexible TEXT.
- **Store / service / handler layers** mirroring the auth slice: `internal/store`
  (pgx queries + typed errors), `internal/service` (business logic, validation,
  aggregation), `internal/handler` (HTTP DTOs, status mapping), `internal/model`
  (domain types). Routes registered in `BuildRouter`.
- **Integration tests** against a real Postgres, in the auth slice's style
  (`t.Skip` when `DATABASE_URL` is absent; tests do not self-migrate).
- **Migration `00003`** — a single index `record(match_id)` (justified in §5). No
  table or column changes.

### Out of scope (non-goals)

- **Any CV / bounce / homography logic.** No ball detection, no bounce
  localization, no zone-from-pixel mapping. `court_x`/`court_y`/`ts_ms` are stored
  verbatim as supplied; nothing computes them. Reason: Phase 3.
- **Video upload / storage.** `match.video_ref` is not written or read by any
  endpoint this slice. Reason: Phase 2.
- **iOS / any Swift.** Reason: separate Phase 1 slice.
- **Exact zone taxonomy enforcement.** `zone` is accepted as any non-empty TEXT;
  no allow-list. Reason: taxonomy still unconfirmed (DESIGN.md "Zone set is
  configurable ... to be confirmed against a court diagram").
- **Editing or deleting shots; editing or deleting matches.** No update/delete
  endpoints this slice (see OQ-3). The rebuild routine (FR-S1) is built and tested
  now so those endpoints are cheap when they land, but no mutation endpoint beyond
  create/add/end exists this slice.
- **Profile CRUD.** Unchanged from Slice 1 (deferred).
- **Pagination / filtering on list endpoints** (see OQ-5). Lists return all of the
  caller's matching rows this slice.
- **Statistics / cross-match aggregation** (Home screen). Reason: Phase 4.

## 3. Acceptance Criteria

Each criterion is independently verifiable. Integration ACs run against a real
Postgres and `t.Skip` when `DATABASE_URL` is unset (auth-slice convention); they do
not self-migrate.

**Build / lint / verification gates**
- [ ] AC1: `go build ./...` passes from `backend/`.
- [ ] AC2: `go vet ./...` passes from `backend/`.
- [ ] AC3: `golangci-lint run ./...` passes from `backend/`.
- [ ] AC4: `go test ./...` is green against a real Postgres that has had all
  migrations (`00001`, `00002`, `00003`) applied via goose; no test applies its own
  migrations.
- [ ] AC5: The existing CI workflow still passes unchanged (no regression in the
  Slice 1 auth/schema tests).

**Migration**
- [ ] AC6: `goose -dir backend/migrations postgres "$DATABASE_URL" up` applies
  cleanly including `00003`, and `... down` one step drops only the `00003` index,
  leaving the `00002` tables intact.
- [ ] AC7: After `up`, an index on `record(match_id)` exists; no `match`, `record`,
  or `match_summary` column, type, nullability, PK, or FK is changed from `00002`.

**Match lifecycle**
- [ ] AC8: `POST /matches` with a valid body creates exactly one `match` row owned
  by the authenticated `user_id`, and returns `201` with the created match
  (including its `match_id` as a JSON string, `ended_at` null).
- [ ] AC9: `POST /matches` with `court_surface` not in {`hard`,`clay`,`grass`}
  returns `400` and creates no row.
- [ ] AC10: `GET /matches` returns `200` with an array containing only matches
  owned by the caller; a second user's matches never appear.
- [ ] AC11: `GET /matches/{id}` for a caller-owned match returns `200` with that
  match.
- [ ] AC12: `POST /matches/{id}/end` on a caller-owned, not-yet-ended match returns
  `200`, sets `ended_at` to a non-null timestamp, and (per AC17/AC18) populates
  `match_summary`.

**Shots (`record`)**
- [ ] AC13: `POST /matches/{id}/records` with a single-element array (or the agreed
  single-object shape, OQ-6) inserts one `record` row linked to that match and
  returns `201`.
- [ ] AC14: `POST /matches/{id}/records` with an N-element array inserts exactly N
  `record` rows in one transaction and returns `201` with the created ids (or count
  — see §6). Reading back via `GET /matches/{id}/records` returns N rows.
- [ ] AC15: If any element of a batch fails validation (bad `source`, empty `zone`,
  or empty batch), the whole request returns `400` and **zero** rows are inserted
  (transaction rolled back).
- [ ] AC16: `GET /matches/{id}/records` for a caller-owned match returns `200` with
  every shot for that match and no shots from any other match.

**Summary aggregation & rebuild**
- [ ] AC17: After `POST /matches/{id}/end`, `match_summary` contains one row per
  distinct `zone` present in that match's `record` rows, each with the correct
  `COUNT(*)` and a non-null `computed_at`; a match with zero shots yields zero
  summary rows.
- [ ] AC18: The aggregation is the exact query
  `SELECT zone, COUNT(*) FROM record WHERE match_id = $1 GROUP BY zone` upserted on
  PK `(match_id, zone)`.
- [ ] AC19 (**rebuild**): Given a match whose summary was already computed, inserting
  additional `record` rows for that match and then invoking the rebuild routine
  produces a summary whose counts equal the new totals, with **no duplicate**
  `(match_id, zone)` rows (upsert overwrites, not appends), and refreshed
  `computed_at`. This is tested directly against the routine (no delete endpoint is
  in scope; see OQ-3).
- [ ] AC19b (**rebuild removes stale zones**): Given a computed summary, deleting all
  `record` rows of one zone directly in the test DB and re-invoking the rebuild
  routine leaves **no** `match_summary` row for that vanished zone, while other
  zones' counts are unaffected. Tested directly against the routine (the task names
  deletion as a rebuild trigger; no delete endpoint ships this slice — see OQ-3).
- [ ] AC20: `GET /matches/{id}/summary` for a caller-owned match returns `200` with
  the per-zone counts (behaviour before end is defined by OQ-1).

**Ownership isolation (cross-cutting)**
- [ ] AC-Z1: For a match owned by a *different* user, each of `GET /matches/{id}`,
  `POST /matches/{id}/end`, `POST /matches/{id}/records`,
  `GET /matches/{id}/records`, and `GET /matches/{id}/summary` returns **`404`** with
  body `{"error":"match not found"}` — byte-for-byte identical to the response for a
  match id that does not exist at all (no existence leak; §4 FR-Z1).
- [ ] AC-Z2: A cross-user mutation attempt (`POST .../records`, `POST .../end`)
  writes nothing — the target match is unchanged and no `record`/`match_summary`
  rows are created.
- [ ] AC-Z3: All gameplay routes are registered behind `RequireAuth`; a request with
  a missing/invalid token returns `401` before any ownership check runs.

## 4. Functional Requirements

### Backend (Go)

- **FR-B1:** New code follows the Slice 1 layout and conventions exactly:
  `internal/store` (pgx/v5 queries on `*Store`, typed sentinel errors like
  `ErrMatchNotFound`), `internal/service` (business logic, validation, aggregation),
  `internal/handler` (HTTP DTOs + status mapping via `writeJSON`/`writeError`),
  `internal/model` (domain types). Handlers never touch the pool directly.
- **FR-B2:** DB access via `pgx/v5` / `pgxpool`; no ORM. UUID PKs are `uuid.UUID`,
  generated application-side in Go (matching `CreateUserWithProfile`, which sets the
  id in the app and lets `created_at` default in the DB).
- **FR-B3:** Errors are returned, never panicked. Structured logging via `slog`
  (`slog.ErrorContext` on unexpected DB errors, as in `middleware.go`).
- **FR-B4:** All gameplay routes registered in `BuildRouter` and wrapped in
  `RequireAuth(tokens, s)`, using Go 1.22 method+pattern routing and path wildcards
  (`GET /matches/{id}`). The authenticated `user_id` is read from context via the
  existing `AuthedUser` mechanism.
- **FR-B5:** Response DTOs serialize every UUID as a JSON **string** (via
  `.String()`), matching auth.go/me.go and the wire contract already shipped
  (`user_id` is a string). This applies to `match_id`, `record_id`, and any nested
  ids.
- **FR-B6:** `match.video_ref` is neither written nor returned by any endpoint this
  slice (out of scope). Match responses omit it or return it as null (§6).

### Ownership isolation (Go)

- **FR-Z1:** Every route that names a `{id}` (match id) resolves the match scoped to
  **both** `match_id = $1 AND user_id = $2` (the authenticated user). If no such row
  exists — whether because the id is unknown or because it belongs to another user —
  the store returns `ErrMatchNotFound` and the handler maps it to **`404`**
  `{"error":"match not found"}`. The two cases are deliberately indistinguishable so
  the API never confirms the existence of another user's match. This is the same
  "no information leak" principle the auth slice applied to login failures (AC16 of
  Slice 1). See §7 for the 404-vs-403 justification.
- **FR-Z2:** Ownership is enforced in the query itself (`WHERE user_id = $2`), not by
  fetching then comparing in Go, so there is no window where another user's row is
  read into memory.

### Match lifecycle (Go)

- **FR-M1:** `POST /matches` — generate a `match_id` and insert a `match` row with
  the caller's `user_id`, `ended_at` NULL, `video_ref` not set. **Requiredness:**
  `court_surface` is required and validated (FR-V1). `location` and `played_at` are
  **optional** (all three columns are nullable in `00002`); when omitted they are
  stored NULL, when present they are stored verbatim (`played_at` parsed as RFC3339;
  an unparseable `played_at` is `400`). This is the baseline; confirm via OQ-9 if a
  match should instead require a location and/or a played-at timestamp.
- **FR-M2:** `GET /matches` — return all matches where `user_id` = caller, newest
  first by `created_at` (ordering stated so the list is deterministic; no
  pagination — OQ-5).
- **FR-M3:** `GET /matches/{id}` — return the caller-owned match or `404` (FR-Z1).
- **FR-M4:** `POST /matches/{id}/end` — in **one transaction**: verify ownership,
  set `ended_at = now()`, and call the rebuild routine (FR-S1) so a match can never
  be marked ended without a consistent summary. Behaviour when the match is already
  ended is governed by OQ-2.

### Shots / `record` (Go)

- **FR-R1:** `POST /matches/{id}/records` — verify ownership (FR-Z1), validate every
  shot (FR-V*), then insert all shots in **one transaction** (mirroring
  `CreateUserWithProfile`'s all-or-nothing pattern). On any validation failure the
  whole batch is rejected `400` with nothing inserted. Each inserted row gets an
  app-generated `record_id`; `created_at` defaults in the DB.
- **FR-R2:** Whether adding shots to an already-ended match is allowed, and whether
  doing so re-runs the rebuild routine, is governed by OQ-3. The rebuild routine
  exists regardless (FR-S1).
- **FR-R3:** `GET /matches/{id}/records` — verify ownership, return all `record`
  rows for the match ordered by `ts_ms` nulls last then `created_at` (deterministic).

### Summary / `match_summary` (Go)

- **FR-S1:** A single idempotent internal routine `rebuildSummary(ctx, tx, matchID)`
  is the *only* writer of `match_summary`. It runs
  `SELECT zone, COUNT(*) FROM record WHERE match_id = $1 GROUP BY zone` and upserts
  each `(match_id, zone, shot_count, computed_at=now())` on the composite PK
  (`INSERT ... ON CONFLICT (match_id, zone) DO UPDATE`). It must also remove any
  stale `(match_id, zone)` rows whose zone no longer appears in `record` (so rebuild
  after removals stays correct — relevant when delete endpoints land). It never
  reads or trusts the existing summary; it is derived purely from `record`.
- **FR-S2:** In-scope callers of `rebuildSummary` this slice: `POST /matches/{id}/end`
  only (inside its transaction). Additional callers (shots-after-end, future
  edit/delete endpoints) are gated by OQ-3 and are not added unless that OQ resolves
  in favour of them.
- **FR-S3:** `match_summary` is never hand-edited or written by any other code path.
  There is no endpoint to set summary rows directly.
- **FR-S4:** `GET /matches/{id}/summary` — verify ownership, return the stored
  `match_summary` rows for the match. It does **not** live-compute (behaviour before
  the match is ended is defined by OQ-1).

### Validation (Go)

- **FR-V1:** `court_surface` is validated against the allow-list
  {`hard`, `clay`, `grass`} at the service layer; a value outside it returns `400`.
  Validation is app-side only — no DB CHECK constraint or enum is added (mirrors
  Slice 1 A-4, which keeps these columns plain TEXT because the taxonomy is not
  frozen). Rationale for validating despite DESIGN.md's `('hard'|'clay'|'grass'|...)`
  is in OQ-4.
- **FR-V2:** `source` is validated against {`cv`, `manual`} at the service layer;
  any other value returns `400`. Behaviour when `source` is omitted is defined by
  OQ-7 (baseline: default to `'manual'`).
- **FR-V3:** `zone` is required to be non-empty but is **not** validated against any
  taxonomy — any non-empty string is accepted and stored verbatim. Reason: zone set
  is unconfirmed (DESIGN.md); enforcing it now would prematurely lock an
  unconfirmed taxonomy.
- **FR-V4:** `court_x`, `court_y`, `ts_ms` are optional. When present they are
  stored verbatim; no range/plausibility checks (no court model exists yet — that is
  Phase 2/3). When absent they are stored NULL.
- **FR-V5:** Malformed JSON, an empty batch array, or a missing required field
  (`zone`) returns `400` with `{"error":"..."}`, matching the auth handlers'
  decode-error pattern.

### iOS (Swift)
- N/A for this slice (explicit non-goal).

### CV Pipeline (Python)
- N/A for this slice (explicit non-goal).

## 5. Data Model Changes

**No table or column changes.** The `match`, `record`, and `match_summary` tables
from `00002_gameplay_tables.sql` are reused exactly as-is (per the task: reuse these,
add only indexes/constraints via a new migration if justified). Restated for
reference (source of truth: `00002`):

- `match(match_id PK, user_id FK→user_login, location, court_surface, played_at,
  video_ref, ended_at, created_at)`
- `record(record_id PK, match_id FK→match, zone, court_x, court_y, ts_ms, source,
  created_at)`
- `match_summary(match_id FK→match, zone, shot_count, computed_at,
  PRIMARY KEY(match_id, zone))`

### New migration `00003_gameplay_indexes.sql` (the one justified addition)

```sql
-- +goose Up
CREATE INDEX idx_record_match_id ON record (match_id);

-- +goose Down
DROP INDEX idx_record_match_id;
```

**Justification:** every read path this slice adds (`GET /matches/{id}/records`) and
the summary aggregation (`... WHERE match_id = $1 GROUP BY zone`) filter `record` by
`match_id`. Without an index these are sequential scans. The index directly backs
the two hottest gameplay queries. It changes no column, type, or constraint, so it
cannot affect the Slice 1 schema ACs. (Note: at single-user volume this is an
optimization, not a correctness requirement — see §7 Performance. Included because
it is cheap, non-breaking, and the natural query shape; if the human prefers zero
schema churn this slice, dropping `00003` is a clean no-op and the endpoints still
function — see OQ-8.)

### Queries introduced this slice

- `match`: insert (create); select-by-user (list); select-by-`(id,user_id)` (get,
  ownership guard); update `ended_at` (end).
- `record`: batch insert; select-by-`match_id` (list).
- `match_summary`: the aggregation `SELECT ... GROUP BY zone`; upsert
  `ON CONFLICT (match_id, zone) DO UPDATE`; delete of stale zones (FR-S1).

## 6. API Contract

All bodies are JSON (`Content-Type: application/json`). Errors use the uniform shape
`{"error":"<message>"}` (Slice 1 convention). All UUIDs are JSON strings. All routes
below require `Authorization: Bearer <jwt>` and return `401` on missing/invalid token
before any other processing.

### `POST /matches`
- **Request:** `{ "court_surface": "hard"|"clay"|"grass", "location"?: string, "played_at"?: string(RFC3339) }`
  — `court_surface` required; `location` and `played_at` optional (FR-M1).
- **201 Created:** `{ "match_id": string, "location": string|null, "court_surface": string, "played_at": string|null, "ended_at": null, "created_at": string }`
- **400:** malformed JSON, missing/invalid `court_surface` (∉ {hard,clay,grass}), or unparseable `played_at`.

### `GET /matches`
- **200 OK:** `[ { match object as above }, ... ]` — caller-owned only, newest first;
  empty array if none.

### `GET /matches/{id}`
- **200 OK:** the match object (as in `POST /matches` response, with `ended_at`
  possibly non-null).
- **404:** unknown id **or** another user's match — `{"error":"match not found"}`.

### `POST /matches/{id}/end`
- **Request:** none (or empty body).
- **200 OK:** the match object with `ended_at` now non-null.
- **404:** unknown / not-owned match.
- **already-ended behaviour:** OQ-2 (baseline: idempotent `200`, or `409` — human
  decides).

### `POST /matches/{id}/records`
- **Request (batch, canonical):**
  `{ "shots": [ { "zone": string, "court_x"?: number, "court_y"?: number, "ts_ms"?: integer, "source"?: "cv"|"manual" }, ... ] }`
  Single insert is the one-element case of the same array (see OQ-6 for whether a
  bare single-object body is also accepted).
- **201 Created:** `{ "created": integer, "record_ids": [string, ...] }` (final shape
  — count vs. full rows — is an implementation choice within this contract; ids
  returned so the client can reference inserted shots).
- **400:** malformed JSON, empty `shots` array, any shot with empty `zone`, or any
  shot with `source` ∉ {cv,manual}. Nothing is inserted (all-or-nothing).
- **404:** unknown / not-owned match.
- **shots-after-end behaviour:** OQ-3.

### `GET /matches/{id}/records`
- **200 OK:** `[ { "record_id": string, "zone": string, "court_x": number|null, "court_y": number|null, "ts_ms": integer|null, "source": string, "created_at": string }, ... ]` — all shots for the match, deterministic order.
- **404:** unknown / not-owned match.

### `GET /matches/{id}/summary`
- **200 OK:** `[ { "zone": string, "shot_count": integer, "computed_at": string }, ... ]` — the stored `match_summary` rows.
- **200 with `[]`** before the match is ended (OQ-1 baseline: return whatever is
  stored, which is empty until end; do not live-compute).
- **404:** unknown / not-owned match.

**Error status summary:** `400` validation/malformed · `401` auth ·
`404` unknown-or-unowned match · `409` reserved for OQ-2 if chosen · `500`
unexpected. No `403` is used (§7).

## 7. Non-Functional Requirements

### Security & authorization

- **All gameplay routes are authenticated** (`RequireAuth`) and **scoped to the
  authenticated `user_id`** — no route trusts a `user_id` from the request body or
  query; it comes only from the verified JWT via context.
- **404, not 403, for another user's resource — chosen and applied consistently.**
  Justification: returning `403 Forbidden` for a match the caller does not own would
  confirm that the match *exists*, leaking information about other users' data. `404`
  for both "does not exist" and "exists but not yours" makes the two cases
  indistinguishable, so the API never reveals the existence of another user's match.
  This is the same non-leaking stance the auth slice took for login (identical
  response for "no such user" and "wrong password"). Applied uniformly to every
  ownership-checked route (§6, AC-Z1). Trade-off accepted: a legitimate owner who
  mistypes their own match id also gets `404` rather than a more specific error —
  acceptable, and correct, since from the server's view the id is simply not one of
  theirs.
- **Data sensitivity:** match/shot data is personal but not credential-grade; no new
  secrets are introduced. No password or token material is logged.

### Performance

- Single-user volume; no latency target. DESIGN.md notes a live `GROUP BY` over one
  match is already instant at this scale, so `match_summary` is an optimization
  (snapshotting at match-end + a dumb-fast Home read), not a correctness requirement.
  The `record(match_id)` index (§5) backs the list and aggregation queries.

## 8. Open Questions

Focused, answerable decisions for the human to resolve at Gate 1 (mirroring Slice 1
OQ-1..OQ-4). Baselines are stated so the spec is buildable if a question is deferred.

- **OQ-1 — `GET /matches/{id}/summary` before the match is ended.** The summary is a
  cache written only at end (FR-S1/FR-S4). Options: (a) return the stored rows,
  which is `[]` until end (baseline); (b) `404`/`409` "not computed yet"; (c)
  live-compute on read. Baseline = (a): return `[]`, never live-compute, because the
  summary is defined as a derived cache built at end.
- **OQ-2 — Ending an already-ended match.** Options: (a) idempotent — re-run end
  (re-set `ended_at`? or leave original?) and return `200`; (b) reject `409`
  "match already ended". This decides whether `ended_at` is immutable once set.
  Baseline = (b) `409`, treating end as a one-time transition.
- **OQ-3 — Are shots allowed after a match is ended, and do edit/delete endpoints
  ship this slice? (load-bearing — it fixes the rebuild-trigger set.)** Options:
  (a) reject `POST .../records` on an ended match (`409`), no edit/delete this slice
  — the only summary trigger is end (baseline); (b) allow shots after end and re-run
  `rebuildSummary` in that request; (c) add explicit edit/delete-shot endpoints this
  slice, each re-running `rebuildSummary`. The rebuild routine (FR-S1) and its direct
  test (AC19) exist under **all** options; this question only decides *which callers*
  invoke it in scope. Baseline = (a).
- **OQ-4 — Validate `court_surface`?** DESIGN.md writes
  `('hard'|'clay'|'grass'|...)` — the `...` signals the set may extend. The task
  instructs validating to exactly {hard,clay,grass}. Baseline follows the task:
  validate app-side to those three, `400` otherwise (FR-V1). Confirm this is desired
  rather than accepting arbitrary surfaces; if extensibility matters sooner, widen
  the allow-list rather than dropping validation.
- **OQ-5 — Pagination on `GET /matches` and `GET /matches/{id}/records`?** Baseline:
  none — return all rows (single-user volume). Confirm no limit/offset or cursor is
  needed this slice.
- **OQ-6 — Batch request shape.** Baseline: canonical body is
  `{"shots":[...]}` and single insert is the one-element case. Should a bare single
  shot object (no wrapping array) also be accepted for ergonomics, or is the array
  the only shape? Baseline: array only (one endpoint, one shape).
- **OQ-7 — Default `source` when omitted.** Baseline: default to `'manual'` (this
  slice's manual-entry path is the Phase-1 use). Alternative: make `source`
  required. Confirm the default.
- **OQ-8 — Add migration `00003` (the `record(match_id)` index) this slice?**
  Baseline: yes (cheap, non-breaking, backs the hot queries). Alternative: defer all
  schema churn to a later slice and rely on the existing tables only. Confirm.
- **OQ-9 — Are `location` and `played_at` required on `POST /matches`?** All three
  match columns are nullable in `00002`. Baseline (FR-M1): `court_surface` required
  and validated; `location` and `played_at` optional (stored NULL when omitted).
  Confirm, or require a location / a played-at timestamp if a match without them is
  not meaningful.

## 9. Assumptions

Where DESIGN.md / the task leave a detail open, these are the explicit assumptions
so the coder has no undocumented decisions. Any can be overridden by the human.

- **A-1 — UUID generation:** `match_id` and `record_id` are generated
  application-side in Go (`uuid.New()`), matching `CreateUserWithProfile` and the
  CLAUDE.md convention. No DB `DEFAULT gen_random_uuid()` is added.
- **A-2 — Timestamps:** `created_at` on `match`/`record` uses the existing DB
  `DEFAULT now()` (from `00002`). `ended_at` and `computed_at` are set to `now()` in
  Go/SQL at end-time. `played_at` is supplied by the client.
- **A-3 — `court_surface`, `source`, `zone` remain plain TEXT** in the DB (no CHECK,
  no enum); all validation is app-side at the service layer (FR-V*). This preserves
  Slice 1 A-4 and avoids locking the unconfirmed zone taxonomy into the schema.
- **A-4 — FK `ON DELETE`:** unchanged from `00002` (PostgreSQL default `NO ACTION`).
  No delete endpoints ship this slice, so cascade decisions stay deferred to the
  slice that introduces deletion.
- **A-5 — Transactions:** batch insert (FR-R1) and end-match+summary (FR-M4/FR-S1)
  each run in a single pgx transaction (`pool.Begin` / `tx.Commit`, with deferred
  `tx.Rollback`), mirroring `CreateUserWithProfile`.
- **A-6 — Router:** routes are added to the existing `BuildRouter` using Go 1.22
  `net/http` method+pattern routing with path wildcards (`{id}`), consistent with
  Slice 1 (no external router). `BuildRouter`'s signature may gain the new handler
  dependency; wiring in `cmd/server/main.go` is updated accordingly.
- **A-7 — Wire types:** UUIDs are JSON strings; `court_x`/`court_y` are JSON numbers
  (REAL); `ts_ms` is a JSON integer; nullable fields serialize as `null` when unset.
- **A-8 — Test harness:** integration tests reuse the Slice 1 pattern — real pool
  from `DATABASE_URL`, `t.Skip` when unset, per-test unique data and `t.Cleanup`
  row deletion, no self-migration. New tests must cover ownership isolation
  (AC-Z*), batch insert (AC14/AC15), and summary aggregation + rebuild
  (AC17-AC19b, including stale-zone removal).

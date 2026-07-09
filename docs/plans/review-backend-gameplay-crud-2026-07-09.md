# Code Review: Backend Gameplay CRUD (Phase 1, Slice 3)

**Date:** 2026-07-09
**Reviewer:** reviewer (AI)
**Branch:** `feat/backend-gameplay-crud` (18 commits ahead of main)
**Verdict:** APPROVED (ship)

Scope reviewed: `git diff main..HEAD -- backend/` — 8 application files, 8 test files.
Verification gate (build / vet / golangci-lint / `go test -race` against real Postgres)
confirmed green by the orchestrator; not re-run here.

## Spec Compliance (spec §3 acceptance criteria)

| AC | Criterion | Status |
|----|-----------|--------|
| AC1–AC3 | build / vet / lint | Confirmed green by orchestrator |
| AC4/AC5 | tests green, CI unchanged | Confirmed green; E2E helper updated for the `BuildRouter` signature change |
| AC6/AC7 | migration 00003 up/down, index exists, no column change | `TestMigration00003_IdxRecordMatchID` asserts index present + all 00002 record columns/types/nullability unchanged |
| AC8 | create → 201, owned, match_id string, ended_at null | E2E `FullFlow` + store `TestMatchCreate_RoundTrip` |
| AC9 | bad court_surface → 400, no row | E2E `BadSurface` asserts 400 **and** 0 rows; service `SurfaceValidation_DBFree` |
| AC10 | list isolation | E2E `ListIsolation` + store `TestListMatches_Isolation` |
| AC11 | get owned → 200 | E2E `FullFlow` |
| AC12 | end → 200, ended_at set, summary populated | store `TestEndMatch_HappyPath_SummaryPopulated` (empty before, populated after commit) |
| AC13 | single insert (1-element array) → 201 | E2E `FullFlow` |
| AC14 | N-element batch → 201, N rows in one tx | store `TestInsertRecords_BatchThenList_Order` + E2E |
| AC15 | any bad element → 400, zero rows | E2E `BadBatch` (empty array / empty zone / bad source, all assert 0 rows) + service unit tests |
| AC16 | list records owned only, deterministic order | store test + E2E (ts_ms ordering asserted with insertion-order-defeating values) |
| AC17 | summary one row/zone, correct counts, zero-shot → 0 rows | `TestRebuildSummary_HappyAggregation` + `_ZeroShot` |
| AC18 | exact `SELECT zone, COUNT(*) … GROUP BY` upsert | Query matches spec verbatim; asserted by rebuild tests |
| AC19 | rebuild overwrites, no dupes, refreshes computed_at | `TestRebuildSummary_Overwrite_NoDupes` (two committed txns to observe now() advance) |
| AC19b | stale-zone removal | `TestRebuildSummary_StaleZoneRemoval` + `_ZeroShot` phase 2 |
| AC20 | summary read, [] before end | E2E `FullFlow` asserts `[]` before end, counts after |
| AC-Z1 | 404 parity, byte-identical | E2E `OwnershipParity` uses `bytes.Equal` across **all 5** `{id}` routes vs a random nonexistent id; store `TestGetMatchOwned_UnknownID` + `_CrossUser` |
| AC-Z2 | no cross-user write | E2E `OwnershipParity` (A's match/records unchanged) + store `TestEndMatch_CrossUser_NotFound` (0 summary rows) |
| AC-Z3 | 401 before ownership | E2E `AuthBeforeOwnership` (8 cases, missing + invalid token) |

Every AC has a real, discriminating test. No AC rests on assertion-free code.

## Load-bearing security invariant — 404-not-403 parity (VERIFIED)

- Ownership is enforced **in the query** on every path: `GetMatchOwned`, `EndMatch`,
  and `InsertRecords` all use `WHERE match_id = $1 AND user_id = $2`. No
  fetch-then-compare-in-Go anywhere; a cross-user row is never read into memory.
  Mutation guards (`EndMatch`, `InsertRecords`) run the predicate **inside the tx**
  with `FOR UPDATE` (FR-Z2).
- Unknown-id and not-owned both collapse to `pgx.ErrNoRows → ErrMatchNotFound →
  404 {"error":"match not found"}`. Unparseable `{id}` also maps to the same 404
  (`parseMatchID`), so a malformed id is indistinguishable too.
- The E2E asserts **byte-identical** bodies (`bytes.Equal`) between the cross-user
  response and a random-nonexistent-id response, per-route, for all five
  ownership-checked routes. This is the strongest form of the no-leak check.

## Transaction correctness (VERIFIED)

- **Batch insert** (`InsertRecords`): `Begin` → `FOR UPDATE` ownership+ended guard →
  per-row inserts → `Commit`, with deferred `Rollback`. Service validates the entire
  batch *before* any store call, so a bad element never opens a tx (all-or-nothing;
  AC15 proven at 0 rows).
- **End-match** (`EndMatch`): one tx sets `ended_at = now()` and calls
  `RebuildSummary` before commit. Proven atomic by
  `TestEndMatch_HappyPath_SummaryPopulated` (summary empty before, present after).
- **RebuildSummary** uses `NOT EXISTS` (not `NOT IN`) for the stale-zone delete —
  correct given `record.zone` is nullable (schema test confirms `zone` is
  `is_nullable = YES`). It is the **sole writer** of `match_summary`, derived purely
  from `record`, never reads the existing summary.

## OQ baselines honored (VERIFIED)

- **OQ-2** end-already-ended → 409 **and** `ended_at` immutable:
  `TestEndMatch_AlreadyEnded_Unchanged` asserts 409 and re-reads `ended_at`,
  comparing with `.Equal()` to the original — the immutability half is genuinely
  tested (this was the one item most at risk of being untested; it is not).
- **OQ-3** shots-after-end → 409: E2E `FullFlow` final step.
- **OQ-1** summary before end → `[]`, no live-compute: `GetSummary` reads stored rows
  only; E2E asserts `[]` before end.
- **OQ-4** court_surface ∈ {hard,clay,grass}: `validCourtSurfaces` map, app-side only.
- **OQ-7** source defaults `'manual'` when nil, validated against {cv,manual}.
- **OQ-5** no pagination. **OQ-6** `{"shots":[...]}` array-only shape.

## Conventions (VERIFIED)

Layered handler → service → store (handlers never touch the pool); pgx/v5, no ORM;
`uuid.UUID` PKs generated app-side (`uuid.New()`); errors returned, never panicked;
`slog.ErrorContext` for unexpected DB errors; uniform `{"error":"..."}` via
`writeError`; all UUIDs serialized as strings via `.String()`; `video_ref` absent
from the model and every DTO (FR-B6); `rows.Close()` deferred on every query;
context propagated throughout. Matches the Slice 1 auth layout exactly.

## Findings

### [NOTE] gameplay.go — AddRecords validates body before the ownership check (intentional, not a leak)

In `AddRecords`, service-layer validation (empty batch / empty zone / bad source)
runs **before** `InsertRecords` reaches the ownership guard. So an *invalid* body
posted to a not-owned or nonexistent match returns **400, not 404**. This is not an
existence leak: the 400 depends only on the request body and is identical whether or
not the match exists, so it reveals nothing about another user's data. The
`OwnershipParity` E2E correctly sends a *valid* body (`{"shots":[{"zone":"net"}]}`)
to reach and assert the 404 path. Ordering is correct and deliberate — recorded here
only so it reads as intentional.

### [NIT] No non-blocking defects found

The per-row `tx.Exec` insert loop (vs `pgx.Batch`) is explicitly sanctioned by the
plan and is correct; at single-user volume it is not a concern. Not a finding.

## Auto-fixes Applied

None. No formatting, typo, or missing-error issues were found; the diff is clean.

## Summary

This slice is a faithful, well-tested implementation of the spec and plan. The
load-bearing security invariant (404 parity enforced in-query, byte-identical bodies)
is implemented correctly and verified by the strongest available assertion. Both
transactions are atomic and proven so; the summary-rebuild logic correctly uses
`NOT EXISTS` and is the sole writer of `match_summary`. Every acceptance criterion —
including the OQ-2 `ended_at`-immutability half that is easy to leave untested — has a
real, discriminating test. No blocking or non-blocking changes required.

**Verdict: APPROVED (ship).**

# Phase 2.2 Functional Slice: Reviewed CV Bounce Import

## Flow
A CV job result is validated against schema version, match identity, video metadata, event timestamps, point bounds, confidence, review status, and the canonical seven-zone taxonomy. GameplayService maps only events whose review status is exactly `accepted` or `corrected` into record inputs and invokes the dedicated transactional CV store operation. The existing manual records API remains unchanged.

## Authority boundary
CV detection is advisory. A bounce becomes an authoritative gameplay record only after an explicit accepted/corrected review state. `needs_review`, `unresolved`, and `rejected` events are excluded. Store-side validation independently rechecks eligibility, zone validity, IDs, and source before inserting. Import must never update or replace a manual record; conflicts are no-op replays or fail safely.

## Idempotency and transaction safety
Derive a stable record UUID from match ID plus CV event ID using a versioned namespace/name scheme. The database should enforce a unique key for `(match_id, source, external_event_id)` (or use the deterministic UUID as a primary-key conflict key). Import locks and verifies the owned, active match and writes the full accepted batch in one transaction. Replaying the same payload produces no duplicate records; payload identity collisions with differing content must return a conflict rather than mutate existing rows. Any batch error rolls back all inserts.

## Verification
`shared/fixtures/golden_bounce_events_7zones.json` is the canonical cross-language fixture consumed by Go backend and Swift TennisCore tests. CI should run Go tests on PostgreSQL and Swift package tests on macOS/Xcode. Until those checks pass, the slice is not considered production-ready.
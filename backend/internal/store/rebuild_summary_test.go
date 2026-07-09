package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// summaryRow mirrors match_summary columns we need to assert on.
type summaryRow struct {
	Zone       string
	ShotCount  int
	ComputedAt time.Time
}

// pgxRows is the minimal interface for iterating query results returned by pgx.
type pgxRows interface {
	Next() bool
	Scan(dest ...interface{}) error
	Close()
	Err() error
}

// scanSummaryRows reads zone→summaryRow from a pgx result set.
func scanSummaryRows(t *testing.T, rows pgxRows) map[string]summaryRow {
	t.Helper()
	result := map[string]summaryRow{}
	for rows.Next() {
		var r summaryRow
		if err := rows.Scan(&r.Zone, &r.ShotCount, &r.ComputedAt); err != nil {
			t.Fatalf("scanSummaryRows Scan: %v", err)
		}
		result[r.Zone] = r
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("scanSummaryRows rows.Err: %v", err)
	}
	return result
}

// TestRebuildSummary_HappyAggregation verifies AC17/AC18:
// a match with shots across several zones produces one match_summary row per
// distinct zone with correct shot_count and a non-zero computed_at.
// All work runs inside a single test-owned tx (Pattern U); the tx is rolled back
// at end so no committed rows remain beyond the match itself.
func TestRebuildSummary_HappyAggregation(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("pool.Begin: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Insert: baseline ×3, net ×2, service ×1 — three distinct zones.
	zones := []string{"baseline", "baseline", "baseline", "net", "net", "service"}
	for _, z := range zones {
		if _, err := tx.Exec(ctx,
			`INSERT INTO record (record_id, match_id, zone, source) VALUES ($1, $2, $3, $4)`,
			uuid.New(), matchID, z, "manual",
		); err != nil {
			t.Fatalf("INSERT record zone=%q: %v", z, err)
		}
	}

	if err := s.RebuildSummary(ctx, tx, matchID); err != nil {
		t.Fatalf("RebuildSummary: %v", err)
	}

	rows, err := tx.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary WHERE match_id = $1`,
		matchID,
	)
	if err != nil {
		t.Fatalf("query match_summary: %v", err)
	}
	defer rows.Close()
	got := scanSummaryRows(t, rows)

	// AC17: one row per distinct zone.
	if len(got) != 3 {
		t.Errorf("summary row count = %d, want 3 (one per zone)", len(got))
	}

	// AC18: exact grouped counts.
	wantCounts := map[string]int{"baseline": 3, "net": 2, "service": 1}
	for zone, wantCount := range wantCounts {
		row, ok := got[zone]
		if !ok {
			t.Errorf("zone %q missing from match_summary", zone)
			continue
		}
		if row.ShotCount != wantCount {
			t.Errorf("zone %q shot_count = %d, want %d", zone, row.ShotCount, wantCount)
		}
		// AC17: computed_at must be non-zero.
		if row.ComputedAt.IsZero() {
			t.Errorf("zone %q computed_at is zero, want non-null timestamp", zone)
		}
	}
}

// TestRebuildSummary_ZeroShot verifies AC17 (zero-shot branch):
// a match with zero records yields zero summary rows; crucially it also verifies
// that the unconditional stale-zone delete removes any prior rows — first we
// insert a record and rebuild (producing 1 summary row), then we delete the
// record and rebuild again, and assert the summary is now empty.
func TestRebuildSummary_ZeroShot(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("pool.Begin: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Phase 1: insert one record and rebuild → 1 summary row.
	recID := uuid.New()
	if _, err := tx.Exec(ctx,
		`INSERT INTO record (record_id, match_id, zone, source) VALUES ($1, $2, $3, $4)`,
		recID, matchID, "baseline", "manual",
	); err != nil {
		t.Fatalf("INSERT record: %v", err)
	}
	if err := s.RebuildSummary(ctx, tx, matchID); err != nil {
		t.Fatalf("RebuildSummary (phase 1): %v", err)
	}

	// Confirm 1 summary row exists via tx.
	var count1 int
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, matchID,
	).Scan(&count1); err != nil {
		t.Fatalf("count phase1: %v", err)
	}
	if count1 != 1 {
		t.Fatalf("phase 1 summary count = %d, want 1 (setup failed)", count1)
	}

	// Phase 2: delete all records then rebuild → must clear the prior summary row.
	if _, err := tx.Exec(ctx,
		`DELETE FROM record WHERE match_id = $1`, matchID,
	); err != nil {
		t.Fatalf("DELETE record: %v", err)
	}
	if err := s.RebuildSummary(ctx, tx, matchID); err != nil {
		t.Fatalf("RebuildSummary (phase 2): %v", err)
	}

	var count2 int
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, matchID,
	).Scan(&count2); err != nil {
		t.Fatalf("count phase2: %v", err)
	}
	if count2 != 0 {
		t.Errorf("summary row count after zero-shot rebuild = %d, want 0", count2)
	}
}

// TestRebuildSummary_Overwrite_NoDupes verifies AC19:
// running RebuildSummary twice (with additional shots inserted between runs)
// overwrites counts, produces no duplicate (match_id, zone) rows, and advances
// computed_at. Because now() is transaction-scoped in Postgres, the two rebuilds
// must be in separate committed transactions to observe a timestamp advance.
func TestRebuildSummary_Overwrite_NoDupes(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// --- Transaction 1: insert initial shots and run first rebuild ---
	tx1, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx1 Begin: %v", err)
	}

	// baseline ×2, net ×1
	for i, z := range []string{"baseline", "baseline", "net"} {
		if _, err := tx1.Exec(ctx,
			`INSERT INTO record (record_id, match_id, zone, source) VALUES ($1, $2, $3, $4)`,
			uuid.New(), matchID, z, "manual",
		); err != nil {
			tx1.Rollback(ctx) //nolint:errcheck
			t.Fatalf("tx1 INSERT[%d]: %v", i, err)
		}
	}
	if err := s.RebuildSummary(ctx, tx1, matchID); err != nil {
		tx1.Rollback(ctx) //nolint:errcheck
		t.Fatalf("tx1 RebuildSummary: %v", err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatalf("tx1 Commit: %v", err)
	}

	// Capture computed_at from tx1's rebuild (read from committed data).
	type zoneTs struct {
		count      int
		computedAt time.Time
	}
	snap1 := map[string]zoneTs{}
	rows1, err := pool.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary WHERE match_id = $1`,
		matchID,
	)
	if err != nil {
		t.Fatalf("snap1 query: %v", err)
	}
	for rows1.Next() {
		var zone string
		var count int
		var ts time.Time
		if err := rows1.Scan(&zone, &count, &ts); err != nil {
			rows1.Close()
			t.Fatalf("snap1 scan: %v", err)
		}
		snap1[zone] = zoneTs{count, ts}
	}
	rows1.Close()
	if err := rows1.Err(); err != nil {
		t.Fatalf("snap1 rows.Err: %v", err)
	}

	if len(snap1) != 2 {
		t.Fatalf("snap1 zone count = %d, want 2 (baseline, net)", len(snap1))
	}

	// --- Transaction 2: insert additional shots and run second rebuild ---
	tx2, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx2 Begin: %v", err)
	}

	// Add baseline ×1 more (new total: 3), service ×2 (new zone)
	for i, z := range []string{"baseline", "service", "service"} {
		if _, err := tx2.Exec(ctx,
			`INSERT INTO record (record_id, match_id, zone, source) VALUES ($1, $2, $3, $4)`,
			uuid.New(), matchID, z, "cv",
		); err != nil {
			tx2.Rollback(ctx) //nolint:errcheck
			t.Fatalf("tx2 INSERT[%d]: %v", i, err)
		}
	}
	if err := s.RebuildSummary(ctx, tx2, matchID); err != nil {
		tx2.Rollback(ctx) //nolint:errcheck
		t.Fatalf("tx2 RebuildSummary: %v", err)
	}
	if err := tx2.Commit(ctx); err != nil {
		t.Fatalf("tx2 Commit: %v", err)
	}

	// Read final summary state via pool (committed).
	snap2 := map[string]zoneTs{}
	rows2, err := pool.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary WHERE match_id = $1`,
		matchID,
	)
	if err != nil {
		t.Fatalf("snap2 query: %v", err)
	}
	for rows2.Next() {
		var zone string
		var count int
		var ts time.Time
		if err := rows2.Scan(&zone, &count, &ts); err != nil {
			rows2.Close()
			t.Fatalf("snap2 scan: %v", err)
		}
		snap2[zone] = zoneTs{count, ts}
	}
	rows2.Close()
	if err := rows2.Err(); err != nil {
		t.Fatalf("snap2 rows.Err: %v", err)
	}

	// AC19: exactly one row per (match_id, zone) — no duplicates.
	// 3 distinct zones: baseline, net, service.
	if len(snap2) != 3 {
		t.Errorf("snap2 zone count = %d, want 3 (baseline, net, service)", len(snap2))
	}

	// AC18: exact new counts.
	wantCounts := map[string]int{"baseline": 3, "net": 1, "service": 2}
	for zone, want := range wantCounts {
		row, ok := snap2[zone]
		if !ok {
			t.Errorf("zone %q missing from snap2", zone)
			continue
		}
		if row.count != want {
			t.Errorf("zone %q count = %d, want %d", zone, row.count, want)
		}
	}

	// AC19: computed_at advanced for zones present in both rebuilds.
	// "baseline" and "net" were in both tx1 and tx2; since the two rebuilds are
	// in different committed transactions, tx2's now() must be >= tx1's.
	for _, zone := range []string{"baseline", "net"} {
		c1, ok1 := snap1[zone]
		c2, ok2 := snap2[zone]
		if !ok1 || !ok2 {
			t.Errorf("zone %q missing from one of the snapshots (ok1=%v ok2=%v)", zone, ok1, ok2)
			continue
		}
		if c2.computedAt.Before(c1.computedAt) {
			t.Errorf("zone %q computed_at regressed: c1=%v c2=%v", zone, c1.computedAt, c2.computedAt)
		}
	}
}

// TestRebuildSummary_StaleZoneRemoval verifies AC19b:
// after a summary is built, deleting all records for one zone and re-running
// RebuildSummary removes that zone's summary row while all other zones' counts
// remain correct and unchanged.
func TestRebuildSummary_StaleZoneRemoval(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("pool.Begin: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Insert: baseline ×3, net ×2, service ×1.
	for _, z := range []string{"baseline", "baseline", "baseline", "net", "net", "service"} {
		if _, err := tx.Exec(ctx,
			`INSERT INTO record (record_id, match_id, zone, source) VALUES ($1, $2, $3, $4)`,
			uuid.New(), matchID, z, "manual",
		); err != nil {
			t.Fatalf("INSERT record zone=%q: %v", z, err)
		}
	}

	// First rebuild — produces 3 summary rows.
	if err := s.RebuildSummary(ctx, tx, matchID); err != nil {
		t.Fatalf("RebuildSummary (build): %v", err)
	}

	var preBuildCount int
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, matchID,
	).Scan(&preBuildCount); err != nil {
		t.Fatalf("count pre-stale: %v", err)
	}
	if preBuildCount != 3 {
		t.Fatalf("pre-stale summary count = %d, want 3 (setup failed)", preBuildCount)
	}

	// Delete all "service" records from within the same tx.
	if _, err := tx.Exec(ctx,
		`DELETE FROM record WHERE match_id = $1 AND zone = $2`, matchID, "service",
	); err != nil {
		t.Fatalf("DELETE service records: %v", err)
	}

	// Second rebuild — should remove the service zone row, update baseline/net.
	if err := s.RebuildSummary(ctx, tx, matchID); err != nil {
		t.Fatalf("RebuildSummary (after delete): %v", err)
	}

	rows, err := tx.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary WHERE match_id = $1`,
		matchID,
	)
	if err != nil {
		t.Fatalf("query after stale removal: %v", err)
	}
	defer rows.Close()
	got := scanSummaryRows(t, rows)

	// AC19b: service zone must be gone.
	if _, exists := got["service"]; exists {
		t.Error("zone 'service' still present in match_summary after all its records were deleted, want removed")
	}

	// AC19b: other zones must be unaffected.
	wantCounts := map[string]int{"baseline": 3, "net": 2}
	for zone, want := range wantCounts {
		row, ok := got[zone]
		if !ok {
			t.Errorf("zone %q missing from match_summary, want present", zone)
			continue
		}
		if row.ShotCount != want {
			t.Errorf("zone %q shot_count = %d, want %d", zone, row.ShotCount, want)
		}
	}

	// Total row count should be exactly 2.
	if len(got) != 2 {
		t.Errorf("summary row count = %d, want 2 (baseline + net)", len(got))
	}
}

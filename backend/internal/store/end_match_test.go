package store_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// TestEndMatch_HappyPath_SummaryPopulated creates a match, inserts shots across
// three zones, calls EndMatch, and asserts:
//   - returned Match.EndedAt is non-nil (AC12)
//   - match_summary has one row per zone with correct counts after commit (AC12, AC17)
//   - summary was empty before EndMatch (proves EndMatch + RebuildSummary committed together)
func TestEndMatch_HappyPath_SummaryPopulated(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// Assert summary is empty before EndMatch.
	var countBefore int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, matchID,
	).Scan(&countBefore); err != nil {
		t.Fatalf("pre-end summary count: %v", err)
	}
	if countBefore != 0 {
		t.Fatalf("expected 0 summary rows before EndMatch, got %d", countBefore)
	}

	// Insert shots: baseline ×3, net ×2, service ×1.
	recs := []model.Record{
		{RecordID: uuid.New(), MatchID: matchID, Zone: "baseline", Source: "manual"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "baseline", Source: "manual"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "baseline", Source: "manual"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "net", Source: "cv"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "net", Source: "cv"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "service", Source: "manual"},
	}
	if err := s.InsertRecords(ctx, matchID, userID, recs); err != nil {
		t.Fatalf("InsertRecords: %v", err)
	}

	// End the match.
	got, err := s.EndMatch(ctx, matchID, userID)
	if err != nil {
		t.Fatalf("EndMatch: %v", err)
	}

	// AC12: returned Match must have non-nil EndedAt.
	if got.EndedAt == nil {
		t.Fatal("EndMatch returned Match.EndedAt is nil, want non-nil")
	}

	// AC12: MatchID and UserID round-trip correctly.
	if got.MatchID != matchID {
		t.Errorf("returned MatchID = %s, want %s", got.MatchID, matchID)
	}
	if got.UserID != userID {
		t.Errorf("returned UserID = %s, want %s", got.UserID, userID)
	}

	// AC12 + AC17: query match_summary via the pool (committed data).
	rows, err := pool.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary WHERE match_id = $1`,
		matchID,
	)
	if err != nil {
		t.Fatalf("query match_summary: %v", err)
	}
	defer rows.Close()
	summary := scanSummaryRows(t, rows)

	// One row per distinct zone.
	if len(summary) != 3 {
		t.Errorf("match_summary row count = %d, want 3 (one per zone)", len(summary))
	}

	// Exact zone counts.
	wantCounts := map[string]int{"baseline": 3, "net": 2, "service": 1}
	for zone, want := range wantCounts {
		row, ok := summary[zone]
		if !ok {
			t.Errorf("zone %q missing from match_summary", zone)
			continue
		}
		if row.ShotCount != want {
			t.Errorf("zone %q shot_count = %d, want %d", zone, row.ShotCount, want)
		}
		if row.ComputedAt.IsZero() {
			t.Errorf("zone %q computed_at is zero, want non-null timestamp", zone)
		}
	}
}

// TestEndMatch_AlreadyEnded_Unchanged ends a match successfully, then calls
// EndMatch a second time and asserts:
//   - second call returns ErrMatchAlreadyEnded (OQ-2)
//   - ended_at in the DB is unchanged (immutable once set)
func TestEndMatch_AlreadyEnded_Unchanged(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// Insert a shot so RebuildSummary has something to work with.
	recs := []model.Record{
		{RecordID: uuid.New(), MatchID: matchID, Zone: "baseline", Source: "manual"},
	}
	if err := s.InsertRecords(ctx, matchID, userID, recs); err != nil {
		t.Fatalf("InsertRecords: %v", err)
	}

	// First EndMatch succeeds.
	first, err := s.EndMatch(ctx, matchID, userID)
	if err != nil {
		t.Fatalf("first EndMatch: %v", err)
	}
	if first.EndedAt == nil {
		t.Fatal("first EndMatch returned nil EndedAt")
	}

	// Second EndMatch must return ErrMatchAlreadyEnded.
	_, err = s.EndMatch(ctx, matchID, userID)
	if !errors.Is(err, store.ErrMatchAlreadyEnded) {
		t.Errorf("second EndMatch: got %v, want ErrMatchAlreadyEnded", err)
	}

	// ended_at must remain unchanged (immutable). Read from DB via GetMatchOwned.
	rereads, err := s.GetMatchOwned(ctx, matchID, userID)
	if err != nil {
		t.Fatalf("GetMatchOwned after second EndMatch: %v", err)
	}
	if rereads.EndedAt == nil {
		t.Fatal("re-read Match.EndedAt is nil after two EndMatch calls, want non-nil")
	}
	// Use time.Time.Equal to compare without monotonic-clock artefacts.
	if !rereads.EndedAt.Equal(*first.EndedAt) {
		t.Errorf("ended_at changed: first=%v, re-read=%v (want unchanged)", *first.EndedAt, *rereads.EndedAt)
	}
}

// TestEndMatch_CrossUser_NotFound calls EndMatch with a different user's ID and
// asserts:
//   - returns ErrMatchNotFound (AC-Z2 / AC-Z1 ownership indistinguishable from unknown)
//   - target match ended_at remains nil (no mutation)
//   - no match_summary rows were created for the target match (AC-Z2)
func TestEndMatch_CrossUser_NotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	ownerID := seedUser(t, pool)
	otherID := seedUser(t, pool)

	matchID := seedMatchWithPool(t, s, ownerID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// Insert shots as the owner so the summary *could* be built.
	recs := []model.Record{
		{RecordID: uuid.New(), MatchID: matchID, Zone: "net", Source: "manual"},
		{RecordID: uuid.New(), MatchID: matchID, Zone: "baseline", Source: "manual"},
	}
	if err := s.InsertRecords(ctx, matchID, ownerID, recs); err != nil {
		t.Fatalf("InsertRecords: %v", err)
	}

	// Attempt to end the match as the wrong user.
	_, err := s.EndMatch(ctx, matchID, otherID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("EndMatch cross-user: got %v, want ErrMatchNotFound", err)
	}

	// Target match must be unchanged: ended_at still nil.
	reread, err := s.GetMatchOwned(ctx, matchID, ownerID)
	if err != nil {
		t.Fatalf("GetMatchOwned after cross-user EndMatch: %v", err)
	}
	if reread.EndedAt != nil {
		t.Errorf("cross-user EndMatch mutated ended_at = %v, want nil", *reread.EndedAt)
	}

	// AC-Z2: no match_summary rows must have been created for this match.
	var summaryCount int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, matchID,
	).Scan(&summaryCount); err != nil {
		t.Fatalf("summary count query: %v", err)
	}
	if summaryCount != 0 {
		t.Errorf("cross-user EndMatch created %d summary rows, want 0", summaryCount)
	}
}

// TestEndMatch_UnknownMatch_NotFound calls EndMatch with a completely unknown
// match ID and asserts ErrMatchNotFound is returned (AC-Z1).
func TestEndMatch_UnknownMatch_NotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	unknownMatchID := uuid.New()

	_, err := s.EndMatch(ctx, unknownMatchID, userID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("EndMatch unknown match: got %v, want ErrMatchNotFound", err)
	}

	// No match_summary rows for the unknown ID.
	var summaryCount int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM match_summary WHERE match_id = $1`, unknownMatchID,
	).Scan(&summaryCount); err != nil {
		t.Fatalf("summary count query: %v", err)
	}
	if summaryCount != 0 {
		t.Errorf("EndMatch on unknown match created %d summary rows, want 0", summaryCount)
	}
}

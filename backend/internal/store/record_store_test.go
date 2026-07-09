package store_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// float32Ptr returns a pointer to the given float32 value.
func float32Ptr(v float32) *float32 { return &v }

// int32Ptr returns a pointer to the given int32 value.
func int32Ptr(v int32) *int32 { return &v }

// seedMatchWithPool creates a match owned by userID. Callers must register
// cleanupMatch separately (FK order: match_summary → record → match).
func seedMatchWithPool(t *testing.T, s *store.Store, userID uuid.UUID) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	matchID := uuid.New()
	m := &model.Match{
		MatchID:      matchID,
		UserID:       userID,
		CourtSurface: "hard",
	}
	if err := s.CreateMatch(ctx, m); err != nil {
		t.Fatalf("seedMatchWithPool CreateMatch: %v", err)
	}
	return matchID
}

// TestInsertRecords_BatchThenList_Order inserts records across two transactions
// to guarantee deterministic created_at ordering, then asserts ListRecords
// returns them in ts_ms ASC NULLS LAST, created_at ASC order (AC14, AC16).
//
// Batch layout (two separate InsertRecords calls so created_at differs):
//   tx1: record B (ts_ms=100), record A (ts_ms=nil)
//   tx2: record D (ts_ms=50),  record E (ts_ms=100), record C (ts_ms=nil)
//
// Expected order: D(50), B(100/tx1), E(100/tx2), A(nil/tx1), C(nil/tx2)
func TestInsertRecords_BatchThenList_Order(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// IDs have mnemonic names matching the expected sort position description.
	idB := uuid.New()
	idA := uuid.New()
	idD := uuid.New()
	idE := uuid.New()
	idC := uuid.New()

	// tx1: B (ts=100), A (ts=nil)
	batch1 := []model.Record{
		{RecordID: idB, MatchID: matchID, Zone: "baseline", TsMs: int32Ptr(100), Source: "manual"},
		{RecordID: idA, MatchID: matchID, Zone: "baseline", TsMs: nil, Source: "manual"},
	}
	if err := s.InsertRecords(ctx, matchID, userID, batch1); err != nil {
		t.Fatalf("InsertRecords batch1: %v", err)
	}

	// tx2: D (ts=50), E (ts=100), C (ts=nil)
	batch2 := []model.Record{
		{RecordID: idD, MatchID: matchID, Zone: "net", TsMs: int32Ptr(50), Source: "cv"},
		{RecordID: idE, MatchID: matchID, Zone: "net", TsMs: int32Ptr(100), Source: "cv"},
		{RecordID: idC, MatchID: matchID, Zone: "net", TsMs: nil, Source: "cv"},
	}
	if err := s.InsertRecords(ctx, matchID, userID, batch2); err != nil {
		t.Fatalf("InsertRecords batch2: %v", err)
	}

	got, err := s.ListRecords(ctx, matchID, userID)
	if err != nil {
		t.Fatalf("ListRecords: %v", err)
	}

	if len(got) != 5 {
		t.Fatalf("ListRecords len = %d, want 5", len(got))
	}

	// Verify all five IDs are present.
	wantIDs := []uuid.UUID{idD, idB, idE, idA, idC}
	for pos, wantID := range wantIDs {
		if got[pos].RecordID != wantID {
			t.Errorf("position %d: got RecordID %s, want %s", pos, got[pos].RecordID, wantID)
		}
	}

	// Verify ts_ms NULLS LAST invariant: all non-nil ts_ms rows precede all nil rows.
	seenNilTs := false
	for _, r := range got {
		if r.TsMs == nil {
			seenNilTs = true
		} else if seenNilTs {
			t.Errorf("ts_ms ordering violated: non-nil ts_ms after nil ts_ms for record %s", r.RecordID)
		}
	}

	// Verify ts_ms ascending among non-nil rows.
	for i := 1; i < len(got); i++ {
		if got[i].TsMs == nil || got[i-1].TsMs == nil {
			break
		}
		if *got[i].TsMs < *got[i-1].TsMs {
			t.Errorf("ts_ms ascending violated: got[%d].TsMs=%d < got[%d].TsMs=%d",
				i, *got[i].TsMs, i-1, *got[i-1].TsMs)
		}
	}
}

// TestInsertRecords_NullableRoundTrip verifies that court_x, court_y, and ts_ms
// round-trip correctly as both NULL and as a value (AC14 / FR-V4).
func TestInsertRecords_NullableRoundTrip(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tests := []struct {
		name    string
		courtX  *float32
		courtY  *float32
		tsMs    *int32
	}{
		{
			name:   "all nullable fields nil",
			courtX: nil,
			courtY: nil,
			tsMs:   nil,
		},
		{
			name:   "all nullable fields set",
			courtX: float32Ptr(3.14),
			courtY: float32Ptr(7.77),
			tsMs:   int32Ptr(42),
		},
		{
			name:   "mixed: courtX set courtY nil tsMs set",
			courtX: float32Ptr(1.0),
			courtY: nil,
			tsMs:   int32Ptr(999),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			userID := seedUser(t, pool)
			matchID := seedMatchWithPool(t, s, userID)
			t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

			recID := uuid.New()
			rec := model.Record{
				RecordID: recID,
				MatchID:  matchID,
				Zone:     "mid",
				CourtX:   tt.courtX,
				CourtY:   tt.courtY,
				TsMs:     tt.tsMs,
				Source:   "manual",
			}
			if err := s.InsertRecords(ctx, matchID, userID, []model.Record{rec}); err != nil {
				t.Fatalf("InsertRecords: %v", err)
			}

			rows, err := s.ListRecords(ctx, matchID, userID)
			if err != nil {
				t.Fatalf("ListRecords: %v", err)
			}
			if len(rows) != 1 {
				t.Fatalf("ListRecords len = %d, want 1", len(rows))
			}
			got := rows[0]

			if got.RecordID != recID {
				t.Errorf("RecordID = %s, want %s", got.RecordID, recID)
			}

			// court_x round-trip
			if tt.courtX == nil {
				if got.CourtX != nil {
					t.Errorf("CourtX = %v, want nil", *got.CourtX)
				}
			} else {
				if got.CourtX == nil {
					t.Fatal("CourtX is nil, want non-nil")
				}
				if *got.CourtX != *tt.courtX {
					t.Errorf("CourtX = %v, want %v", *got.CourtX, *tt.courtX)
				}
			}

			// court_y round-trip
			if tt.courtY == nil {
				if got.CourtY != nil {
					t.Errorf("CourtY = %v, want nil", *got.CourtY)
				}
			} else {
				if got.CourtY == nil {
					t.Fatal("CourtY is nil, want non-nil")
				}
				if *got.CourtY != *tt.courtY {
					t.Errorf("CourtY = %v, want %v", *got.CourtY, *tt.courtY)
				}
			}

			// ts_ms round-trip
			if tt.tsMs == nil {
				if got.TsMs != nil {
					t.Errorf("TsMs = %v, want nil", *got.TsMs)
				}
			} else {
				if got.TsMs == nil {
					t.Fatal("TsMs is nil, want non-nil")
				}
				if *got.TsMs != *tt.tsMs {
					t.Errorf("TsMs = %v, want %v", *got.TsMs, *tt.tsMs)
				}
			}

			// created_at must be non-zero
			if got.CreatedAt.IsZero() {
				t.Error("CreatedAt is zero, want DB-populated timestamp")
			}
		})
	}
}

// TestInsertRecords_CrossUser_ErrMatchNotFound verifies that inserting records
// into another user's match returns ErrMatchNotFound and writes zero rows into
// the DB (AC-Z2).
func TestInsertRecords_CrossUser_ErrMatchNotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	ownerID := seedUser(t, pool)
	otherID := seedUser(t, pool)

	matchID := seedMatchWithPool(t, s, ownerID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	rec := model.Record{
		RecordID: uuid.New(),
		MatchID:  matchID,
		Zone:     "baseline",
		Source:   "manual",
	}

	// Insert as the wrong user.
	err := s.InsertRecords(ctx, matchID, otherID, []model.Record{rec})
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("InsertRecords cross-user: got %v, want ErrMatchNotFound", err)
	}

	// Verify zero rows were written for this match.
	var count int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM record WHERE match_id = $1`, matchID,
	).Scan(&count); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 0 {
		t.Errorf("record count after cross-user insert = %d, want 0", count)
	}
}

// TestInsertRecords_UnknownMatch_ErrMatchNotFound verifies that inserting
// records against a non-existent match returns ErrMatchNotFound and writes
// zero rows (AC-Z2).
func TestInsertRecords_UnknownMatch_ErrMatchNotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	unknownMatchID := uuid.New()

	rec := model.Record{
		RecordID: uuid.New(),
		MatchID:  unknownMatchID,
		Zone:     "net",
		Source:   "manual",
	}

	err := s.InsertRecords(ctx, unknownMatchID, userID, []model.Record{rec})
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("InsertRecords unknown match: got %v, want ErrMatchNotFound", err)
	}

	// The unknown match has no rows anyway, but confirm the record table is
	// also clean (no row slipped through with the match_id FK broken).
	var count int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM record WHERE match_id = $1`, unknownMatchID,
	).Scan(&count); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 0 {
		t.Errorf("record count for unknown match = %d, want 0", count)
	}
}

// TestListRecords_Isolation verifies that ListRecords returns only the target
// match's shots and nothing from a different match owned by the same user (AC16).
func TestListRecords_Isolation(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)

	matchA := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchA) })

	matchB := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchB) })

	// Insert 2 records into matchA, 3 into matchB.
	recsA := []model.Record{
		{RecordID: uuid.New(), MatchID: matchA, Zone: "z1", Source: "manual"},
		{RecordID: uuid.New(), MatchID: matchA, Zone: "z2", Source: "manual"},
	}
	recsB := []model.Record{
		{RecordID: uuid.New(), MatchID: matchB, Zone: "z3", Source: "cv"},
		{RecordID: uuid.New(), MatchID: matchB, Zone: "z4", Source: "cv"},
		{RecordID: uuid.New(), MatchID: matchB, Zone: "z5", Source: "cv"},
	}

	if err := s.InsertRecords(ctx, matchA, userID, recsA); err != nil {
		t.Fatalf("InsertRecords matchA: %v", err)
	}
	if err := s.InsertRecords(ctx, matchB, userID, recsB); err != nil {
		t.Fatalf("InsertRecords matchB: %v", err)
	}

	gotA, err := s.ListRecords(ctx, matchA, userID)
	if err != nil {
		t.Fatalf("ListRecords matchA: %v", err)
	}
	if len(gotA) != 2 {
		t.Errorf("ListRecords(matchA) len = %d, want 2", len(gotA))
	}
	for _, r := range gotA {
		if r.MatchID != matchA {
			t.Errorf("ListRecords(matchA): got record with match_id %s, want %s", r.MatchID, matchA)
		}
	}

	gotB, err := s.ListRecords(ctx, matchB, userID)
	if err != nil {
		t.Fatalf("ListRecords matchB: %v", err)
	}
	if len(gotB) != 3 {
		t.Errorf("ListRecords(matchB) len = %d, want 3", len(gotB))
	}
	for _, r := range gotB {
		if r.MatchID != matchB {
			t.Errorf("ListRecords(matchB): got record with match_id %s, want %s", r.MatchID, matchB)
		}
	}
}

// TestListRecords_Empty verifies that ListRecords returns a non-nil empty
// slice when the match exists but has no records (AC16 empty-slice guarantee).
func TestListRecords_Empty(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	got, err := s.ListRecords(ctx, matchID, userID)
	if err != nil {
		t.Fatalf("ListRecords: %v", err)
	}
	if got == nil {
		t.Error("ListRecords returned nil, want non-nil empty slice")
	}
	if len(got) != 0 {
		t.Errorf("ListRecords len = %d, want 0", len(got))
	}
}

// TestListRecords_CrossUser_ErrMatchNotFound verifies that listing another
// user's match returns ErrMatchNotFound (AC-Z2 / AC16 ownership guard).
func TestListRecords_CrossUser_ErrMatchNotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	ownerID := seedUser(t, pool)
	otherID := seedUser(t, pool)

	matchID := seedMatchWithPool(t, s, ownerID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	_, err := s.ListRecords(ctx, matchID, otherID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("ListRecords cross-user: got %v, want ErrMatchNotFound", err)
	}
}

// TestListRecords_UnknownMatch_ErrMatchNotFound verifies that listing an
// entirely unknown match returns ErrMatchNotFound (AC-Z2).
func TestListRecords_UnknownMatch_ErrMatchNotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)

	_, err := s.ListRecords(ctx, uuid.New(), userID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("ListRecords unknown match: got %v, want ErrMatchNotFound", err)
	}
}

// TestInsertRecords_AlreadyEnded verifies that inserting records into an
// already-ended match returns ErrMatchAlreadyEnded and writes zero rows (OQ-3).
// ended_at is set via a raw UPDATE since EndMatch (Task 6) is not yet implemented.
func TestInsertRecords_AlreadyEnded(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)
	matchID := seedMatchWithPool(t, s, userID)
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	// End the match directly via SQL (EndMatch not yet implemented).
	if _, err := pool.Exec(ctx,
		`UPDATE match SET ended_at = now() WHERE match_id = $1`, matchID,
	); err != nil {
		t.Fatalf("UPDATE ended_at: %v", err)
	}

	rec := model.Record{
		RecordID: uuid.New(),
		MatchID:  matchID,
		Zone:     "service",
		Source:   "manual",
	}

	err := s.InsertRecords(ctx, matchID, userID, []model.Record{rec})
	if !errors.Is(err, store.ErrMatchAlreadyEnded) {
		t.Errorf("InsertRecords ended match: got %v, want ErrMatchAlreadyEnded", err)
	}

	// Verify zero rows written.
	var count int
	if err := pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM record WHERE match_id = $1`, matchID,
	).Scan(&count); err != nil {
		t.Fatalf("count query: %v", err)
	}
	if count != 0 {
		t.Errorf("record count after ended-match insert = %d, want 0", count)
	}
}

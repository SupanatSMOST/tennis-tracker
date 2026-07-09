package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// seedUser inserts a user_login + profile row and registers its cleanup via
// t.Cleanup. Returns the new userID. Reuses CreateUserWithProfile so the FK
// path mirrors production.
func seedUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	userID := uuid.New()
	username := uniqueUsername("matchtest")
	s := store.New(pool)
	u := model.User{
		UserID:       userID,
		Username:     username,
		PasswordHash: "$2a$12$fakehashformatchtest",
	}
	if err := s.CreateUserWithProfile(context.Background(), u); err != nil {
		t.Fatalf("seedUser CreateUserWithProfile: %v", err)
	}
	t.Cleanup(func() { cleanupUser(t, pool, userID) })
	return userID
}

// cleanupMatch deletes match_summary → record → match rows for the given
// matchID in FK order so the caller's user_login can be cleaned up afterward.
func cleanupMatch(t *testing.T, pool *pgxpool.Pool, matchID uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `DELETE FROM match_summary WHERE match_id = $1`, matchID); err != nil {
		t.Logf("cleanup match_summary %s: %v", matchID, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM record WHERE match_id = $1`, matchID); err != nil {
		t.Logf("cleanup record %s: %v", matchID, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM match WHERE match_id = $1`, matchID); err != nil {
		t.Logf("cleanup match %s: %v", matchID, err)
	}
}

// ptr helpers for nullable fields.
func strPtr(s string) *string    { return &s }
func timePtr(t time.Time) *time.Time { return &t }

// TestMatchCreate_RoundTrip_NullableFields creates a match with all nullable
// fields absent (NULL) and one with both set, then verifies create→get
// round-trip fields are intact, ended_at is nil, and created_at is populated
// (AC8, AC11).
func TestMatchCreate_RoundTrip_NullableFields(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tests := []struct {
		name     string
		location *string
		playedAt *time.Time
	}{
		{
			name:     "nulls omitted",
			location: nil,
			playedAt: nil,
		},
		{
			name:     "both set",
			location: strPtr("Centre Court"),
			playedAt: timePtr(time.Now().UTC().Truncate(time.Microsecond)),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			userID := seedUser(t, pool)

			matchID := uuid.New()
			m := &model.Match{
				MatchID:      matchID,
				UserID:       userID,
				Location:     tt.location,
				CourtSurface: "hard",
				PlayedAt:     tt.playedAt,
			}

			t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

			if err := s.CreateMatch(ctx, m); err != nil {
				t.Fatalf("CreateMatch: %v", err)
			}

			// RETURNING must have populated CreatedAt.
			if m.CreatedAt.IsZero() {
				t.Error("CreateMatch: m.CreatedAt is zero after RETURNING, want DB timestamp")
			}

			got, err := s.GetMatchOwned(ctx, matchID, userID)
			if err != nil {
				t.Fatalf("GetMatchOwned: %v", err)
			}

			if got.MatchID != matchID {
				t.Errorf("MatchID = %s, want %s", got.MatchID, matchID)
			}
			if got.UserID != userID {
				t.Errorf("UserID = %s, want %s", got.UserID, userID)
			}
			if got.CourtSurface != "hard" {
				t.Errorf("CourtSurface = %q, want %q", got.CourtSurface, "hard")
			}
			if got.EndedAt != nil {
				t.Errorf("EndedAt = %v, want nil (match not yet ended)", got.EndedAt)
			}
			if got.CreatedAt.IsZero() {
				t.Error("CreatedAt from GetMatchOwned is zero")
			}

			// nullable location round-trip
			if tt.location == nil {
				if got.Location != nil {
					t.Errorf("Location = %v, want nil", *got.Location)
				}
			} else {
				if got.Location == nil {
					t.Fatal("Location is nil, want non-nil")
				}
				if *got.Location != *tt.location {
					t.Errorf("Location = %q, want %q", *got.Location, *tt.location)
				}
			}

			// nullable played_at round-trip
			if tt.playedAt == nil {
				if got.PlayedAt != nil {
					t.Errorf("PlayedAt = %v, want nil", got.PlayedAt)
				}
			} else {
				if got.PlayedAt == nil {
					t.Fatal("PlayedAt is nil, want non-nil")
				}
				if !got.PlayedAt.Equal(*tt.playedAt) {
					t.Errorf("PlayedAt = %v, want %v", got.PlayedAt, *tt.playedAt)
				}
			}
		})
	}
}

// TestListMatches_Empty verifies that ListMatches returns a non-nil empty
// slice when the user has no matches (AC10 / empty-slice guarantee).
func TestListMatches_Empty(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)

	got, err := s.ListMatches(ctx, userID)
	if err != nil {
		t.Fatalf("ListMatches: %v", err)
	}
	if got == nil {
		t.Error("ListMatches returned nil, want non-nil empty slice")
	}
	if len(got) != 0 {
		t.Errorf("ListMatches len = %d, want 0", len(got))
	}
}

// TestListMatches_NewestFirst creates several matches for one user and asserts
// they are returned in non-increasing created_at order (AC10 newest-first).
func TestListMatches_NewestFirst(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)

	const n = 3
	created := make([]uuid.UUID, n)
	for i := 0; i < n; i++ {
		matchID := uuid.New()
		m := &model.Match{
			MatchID:      matchID,
			UserID:       userID,
			CourtSurface: "clay",
		}
		t.Cleanup(func() { cleanupMatch(t, pool, matchID) })
		if err := s.CreateMatch(ctx, m); err != nil {
			t.Fatalf("CreateMatch[%d]: %v", i, err)
		}
		created[i] = matchID
	}

	got, err := s.ListMatches(ctx, userID)
	if err != nil {
		t.Fatalf("ListMatches: %v", err)
	}
	if len(got) != n {
		t.Fatalf("ListMatches len = %d, want %d", len(got), n)
	}

	// Verify all created IDs are present.
	seen := make(map[uuid.UUID]bool, n)
	for _, m := range got {
		seen[m.MatchID] = true
	}
	for _, id := range created {
		if !seen[id] {
			t.Errorf("expected match %s in list but not found", id)
		}
	}

	// Verify non-increasing order (created_at DESC).
	for i := 1; i < len(got); i++ {
		if got[i].CreatedAt.After(got[i-1].CreatedAt) {
			t.Errorf("order violation: got[%d].CreatedAt (%v) > got[%d].CreatedAt (%v)",
				i, got[i].CreatedAt, i-1, got[i-1].CreatedAt)
		}
	}
}

// TestListMatches_Isolation verifies that user A never sees user B's matches
// and vice versa (AC10 list isolation).
func TestListMatches_Isolation(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userA := seedUser(t, pool)
	userB := seedUser(t, pool)

	// Seed two matches for A, one match for B.
	for i := 0; i < 2; i++ {
		matchID := uuid.New()
		m := &model.Match{
			MatchID:      matchID,
			UserID:       userA,
			CourtSurface: "grass",
		}
		t.Cleanup(func() { cleanupMatch(t, pool, matchID) })
		if err := s.CreateMatch(ctx, m); err != nil {
			t.Fatalf("CreateMatch for A[%d]: %v", i, err)
		}
	}

	matchBID := uuid.New()
	mB := &model.Match{
		MatchID:      matchBID,
		UserID:       userB,
		CourtSurface: "hard",
	}
	t.Cleanup(func() { cleanupMatch(t, pool, matchBID) })
	if err := s.CreateMatch(ctx, mB); err != nil {
		t.Fatalf("CreateMatch for B: %v", err)
	}

	// A sees exactly 2 rows, all owned by A.
	listA, err := s.ListMatches(ctx, userA)
	if err != nil {
		t.Fatalf("ListMatches(A): %v", err)
	}
	if len(listA) != 2 {
		t.Errorf("ListMatches(A) len = %d, want 2", len(listA))
	}
	for _, m := range listA {
		if m.UserID != userA {
			t.Errorf("ListMatches(A): got row with user_id %s, want %s", m.UserID, userA)
		}
	}

	// B sees exactly 1 row, owned by B.
	listB, err := s.ListMatches(ctx, userB)
	if err != nil {
		t.Fatalf("ListMatches(B): %v", err)
	}
	if len(listB) != 1 {
		t.Errorf("ListMatches(B) len = %d, want 1", len(listB))
	}
	if listB[0].UserID != userB {
		t.Errorf("ListMatches(B): got row with user_id %s, want %s", listB[0].UserID, userB)
	}
	// A's matches must not appear in B's list.
	for _, m := range listB {
		if m.UserID == userA {
			t.Errorf("ListMatches(B): found A's match %s in B's list", m.MatchID)
		}
	}
}

// TestGetMatchOwned_UnknownID verifies that GetMatchOwned returns ErrMatchNotFound
// for a match ID that does not exist in the DB (AC11 / AC-Z1).
func TestGetMatchOwned_UnknownID(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	userID := seedUser(t, pool)

	_, err := s.GetMatchOwned(ctx, uuid.New(), userID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("GetMatchOwned unknown id: got %v, want ErrMatchNotFound", err)
	}
}

// TestGetMatchOwned_CrossUser verifies that GetMatchOwned returns ErrMatchNotFound
// when the match exists but belongs to a different user (AC-Z1 ownership guard:
// unknown and not-owned are indistinguishable).
func TestGetMatchOwned_CrossUser(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)
	ctx := context.Background()

	ownerID := seedUser(t, pool)
	otherID := seedUser(t, pool)

	matchID := uuid.New()
	m := &model.Match{
		MatchID:      matchID,
		UserID:       ownerID,
		CourtSurface: "hard",
	}
	t.Cleanup(func() { cleanupMatch(t, pool, matchID) })

	if err := s.CreateMatch(ctx, m); err != nil {
		t.Fatalf("CreateMatch: %v", err)
	}

	// Owner can retrieve it.
	_, err := s.GetMatchOwned(ctx, matchID, ownerID)
	if err != nil {
		t.Fatalf("GetMatchOwned for owner: unexpected error %v", err)
	}

	// Other user must get ErrMatchNotFound.
	_, err = s.GetMatchOwned(ctx, matchID, otherID)
	if !errors.Is(err, store.ErrMatchNotFound) {
		t.Errorf("GetMatchOwned cross-user: got %v, want ErrMatchNotFound", err)
	}
}

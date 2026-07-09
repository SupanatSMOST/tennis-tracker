package store_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Supanat-Smost/tennis/backend/internal/model"
	"github.com/Supanat-Smost/tennis/backend/internal/store"
)

// buildPool opens a real pool from DATABASE_URL or skips the test.
func buildPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping integration test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Fatalf("pool.Ping: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// uniqueUsername returns a username that is unique per test run.
func uniqueUsername(base string) string {
	return fmt.Sprintf("%s_%s", base, uuid.New().String()[:8])
}

// cleanupUser removes profile then user_login rows for the given user_id (FK order).
func cleanupUser(t *testing.T, pool *pgxpool.Pool, userID uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `DELETE FROM profile WHERE user_id = $1`, userID); err != nil {
		t.Logf("cleanup profile %s: %v", userID, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM user_login WHERE user_id = $1`, userID); err != nil {
		t.Logf("cleanup user_login %s: %v", userID, err)
	}
}

// countRow counts rows in table matching a user_id.
func countByUserID(t *testing.T, pool *pgxpool.Pool, table string, userID uuid.UUID) int {
	t.Helper()
	var n int
	q := fmt.Sprintf(`SELECT count(*) FROM %s WHERE user_id = $1`, table) //nolint:gosec
	if err := pool.QueryRow(context.Background(), q, userID).Scan(&n); err != nil {
		t.Fatalf("countByUserID(%s, %s): %v", table, userID, err)
	}
	return n
}

// countByUsername counts user_login rows matching a username.
func countByUsername(t *testing.T, pool *pgxpool.Pool, username string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM user_login WHERE username = $1`, username).Scan(&n); err != nil {
		t.Fatalf("countByUsername(%s): %v", username, err)
	}
	return n
}

// TestCreateUserWithProfile_HappyPath verifies that a successful creation
// inserts exactly one user_login row and one profile row, with display_name
// equal to the username and avatar_url NULL.
func TestCreateUserWithProfile_HappyPath(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	userID := uuid.New()
	username := uniqueUsername("happath")
	u := model.User{
		UserID:       userID,
		Username:     username,
		PasswordHash: "$2a$12$fakehashfortest",
	}

	t.Cleanup(func() { cleanupUser(t, pool, userID) })

	if err := s.CreateUserWithProfile(context.Background(), u); err != nil {
		t.Fatalf("CreateUserWithProfile: unexpected error: %v", err)
	}

	// Assert exactly one user_login row.
	if got := countByUserID(t, pool, "user_login", userID); got != 1 {
		t.Errorf("user_login count = %d, want 1", got)
	}

	// Assert exactly one profile row.
	if got := countByUserID(t, pool, "profile", userID); got != 1 {
		t.Errorf("profile count = %d, want 1", got)
	}

	// Assert display_name == username and avatar_url IS NULL.
	var displayName string
	var avatarURL *string
	err := pool.QueryRow(context.Background(),
		`SELECT display_name, avatar_url FROM profile WHERE user_id = $1`, userID,
	).Scan(&displayName, &avatarURL)
	if err != nil {
		t.Fatalf("SELECT profile: %v", err)
	}
	if displayName != username {
		t.Errorf("display_name = %q, want %q", displayName, username)
	}
	if avatarURL != nil {
		t.Errorf("avatar_url = %v, want nil", *avatarURL)
	}
}

// TestCreateUserWithProfile_DuplicateUsername verifies AC14: a second insert with
// the same username (but different user_id) returns ErrUsernameTaken and leaves
// no orphan rows in either user_login or profile.
func TestCreateUserWithProfile_DuplicateUsername(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	username := uniqueUsername("dupname")

	// First user — clean up on exit.
	idA := uuid.New()
	uA := model.User{
		UserID:       idA,
		Username:     username,
		PasswordHash: "$2a$12$fakehashA",
	}
	t.Cleanup(func() { cleanupUser(t, pool, idA) })

	if err := s.CreateUserWithProfile(context.Background(), uA); err != nil {
		t.Fatalf("first CreateUserWithProfile: %v", err)
	}

	// Second user — same username, distinct id.
	idB := uuid.New()
	uB := model.User{
		UserID:       idB,
		Username:     username,
		PasswordHash: "$2a$12$fakehashB",
	}
	// idB rows should not exist, but clean up defensively.
	t.Cleanup(func() { cleanupUser(t, pool, idB) })

	err := s.CreateUserWithProfile(context.Background(), uB)
	if !errors.Is(err, store.ErrUsernameTaken) {
		t.Fatalf("second create: got err = %v, want ErrUsernameTaken", err)
	}

	// Transaction must have rolled back: no profile row for idB.
	if got := countByUserID(t, pool, "profile", idB); got != 0 {
		t.Errorf("profile rows for idB = %d after rollback, want 0 (orphan row leaked)", got)
	}

	// Only one user_login row for this username (idA's).
	if got := countByUsername(t, pool, username); got != 1 {
		t.Errorf("user_login rows for username %q = %d, want 1", username, got)
	}
}

// TestGetUserByUsername_RoundTrip verifies that a created user can be retrieved
// by username with all fields intact.
func TestGetUserByUsername_RoundTrip(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	userID := uuid.New()
	username := uniqueUsername("getuname")
	hash := "$2a$12$fakehashRT"
	u := model.User{
		UserID:       userID,
		Username:     username,
		PasswordHash: hash,
	}
	t.Cleanup(func() { cleanupUser(t, pool, userID) })

	if err := s.CreateUserWithProfile(context.Background(), u); err != nil {
		t.Fatalf("CreateUserWithProfile: %v", err)
	}

	got, err := s.GetUserByUsername(context.Background(), username)
	if err != nil {
		t.Fatalf("GetUserByUsername: %v", err)
	}

	if got.UserID != userID {
		t.Errorf("UserID = %s, want %s", got.UserID, userID)
	}
	if got.Username != username {
		t.Errorf("Username = %q, want %q", got.Username, username)
	}
	if got.PasswordHash != hash {
		t.Errorf("PasswordHash = %q, want %q", got.PasswordHash, hash)
	}
	if got.CreatedAt.IsZero() {
		t.Error("CreatedAt is zero, want DB-populated timestamp")
	}
}

// TestGetUserByUsername_NotFound verifies that an unknown username returns ErrUserNotFound.
func TestGetUserByUsername_NotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	_, err := s.GetUserByUsername(context.Background(), "definitely_does_not_exist_"+uuid.New().String())
	if !errors.Is(err, store.ErrUserNotFound) {
		t.Errorf("GetUserByUsername unknown: got %v, want ErrUserNotFound", err)
	}
}

// TestGetUserByID_RoundTrip verifies that a created user can be retrieved by ID.
func TestGetUserByID_RoundTrip(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	userID := uuid.New()
	username := uniqueUsername("getbyid")
	hash := "$2a$12$fakehashID"
	u := model.User{
		UserID:       userID,
		Username:     username,
		PasswordHash: hash,
	}
	t.Cleanup(func() { cleanupUser(t, pool, userID) })

	if err := s.CreateUserWithProfile(context.Background(), u); err != nil {
		t.Fatalf("CreateUserWithProfile: %v", err)
	}

	got, err := s.GetUserByID(context.Background(), userID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}

	if got.UserID != userID {
		t.Errorf("UserID = %s, want %s", got.UserID, userID)
	}
	if got.Username != username {
		t.Errorf("Username = %q, want %q", got.Username, username)
	}
	if got.PasswordHash != hash {
		t.Errorf("PasswordHash = %q, want %q", got.PasswordHash, hash)
	}
	if got.CreatedAt.IsZero() {
		t.Error("CreatedAt is zero, want DB-populated timestamp")
	}
}

// TestGetUserByID_NotFound verifies that an unknown id returns ErrUserNotFound.
func TestGetUserByID_NotFound(t *testing.T) {
	pool := buildPool(t)
	s := store.New(pool)

	_, err := s.GetUserByID(context.Background(), uuid.New())
	if !errors.Is(err, store.ErrUserNotFound) {
		t.Errorf("GetUserByID unknown: got %v, want ErrUserNotFound", err)
	}
}

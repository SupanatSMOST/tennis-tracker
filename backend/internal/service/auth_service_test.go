package service_test

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// authTestHarness holds the constructed services and the raw pool for assertions.
type authTestHarness struct {
	svc    *service.AuthService
	tokens *service.TokenService
	pool   *pgxpool.Pool
}

// newTestAuthService constructs a real AuthService backed by the Postgres cluster
// at DATABASE_URL. The test is skipped if DATABASE_URL is unset; it fails loudly
// if DATABASE_URL is set but unreachable.
func newTestAuthService(t *testing.T) authTestHarness {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set; skipping integration tests")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Fatalf("DB unreachable at %s: %v", dbURL, err)
	}

	t.Cleanup(pool.Close)

	st := store.New(pool)
	tok := service.NewTokenService([]byte("test-signing-key-for-auth-svc-tests"))
	svc := service.NewAuthService(st, tok)

	return authTestHarness{svc: svc, tokens: tok, pool: pool}
}

// uniqueUsername returns a username that is unique per test run.
func uniqueUsername() string {
	return "u_" + uuid.NewString()
}

// registerUserCleanup registers a t.Cleanup that removes the user_login + profile
// rows created under username. Profile must be deleted first (FK ON DELETE NO ACTION).
func registerUserCleanup(t *testing.T, pool *pgxpool.Pool, userID uuid.UUID) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		// profile has FK → user_login; delete profile first.
		pool.Exec(ctx, "DELETE FROM profile WHERE user_id = $1", userID)    //nolint:errcheck
		pool.Exec(ctx, "DELETE FROM user_login WHERE user_id = $1", userID) //nolint:errcheck
	})
}

// ---------------------------------------------------------------------------
// Test: Signup happy path
// ---------------------------------------------------------------------------

// TestAuthService_Signup_HappyPath tests that Signup:
//   - returns a User with a non-empty UserID and Username (AC13)
//   - returns a non-empty token (OQ-2 — auto-login)
//   - the token parses back to the user's UUID (AC15)
//   - the stored password_hash is not the plaintext and bcrypt-verifies (AC13)
func TestAuthService_Signup_HappyPath(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	username := uniqueUsername()
	password := "correct-horse-battery"

	user, tok, err := h.svc.Signup(ctx, username, password)
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	if user.UserID == uuid.Nil {
		t.Error("Signup() returned zero UserID")
	}
	if user.Username != username {
		t.Errorf("Signup() Username = %q, want %q", user.Username, username)
	}
	if tok == "" {
		t.Error("Signup() returned empty token")
	}

	// Token must parse back to the user's UUID.
	parsedID, err := h.tokens.Parse(tok)
	if err != nil {
		t.Fatalf("tokens.Parse(tok) unexpected error: %v", err)
	}
	if parsedID != user.UserID {
		t.Errorf("token sub = %v, want %v", parsedID, user.UserID)
	}

	// Stored password_hash must not be the plaintext and must bcrypt-verify.
	var storedHash string
	err = h.pool.QueryRow(ctx,
		"SELECT password_hash FROM user_login WHERE user_id = $1", user.UserID,
	).Scan(&storedHash)
	if err != nil {
		t.Fatalf("SELECT password_hash: %v", err)
	}
	if storedHash == password {
		t.Error("stored password_hash equals the plaintext (AC13 violated)")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(password)); err != nil {
		t.Errorf("bcrypt.CompareHashAndPassword failed on stored hash: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Test: Signup then Login round-trip
// ---------------------------------------------------------------------------

// TestAuthService_Login_RoundTrip tests that a user created with Signup can
// login with the correct password and receive a token whose sub matches the UUID.
func TestAuthService_Login_RoundTrip(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	username := uniqueUsername()
	password := "roundtrip-password-99"

	user, _, err := h.svc.Signup(ctx, username, password)
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	tok, err := h.svc.Login(ctx, username, password)
	if err != nil {
		t.Fatalf("Login() unexpected error: %v", err)
	}
	if tok == "" {
		t.Error("Login() returned empty token")
	}

	parsedID, err := h.tokens.Parse(tok)
	if err != nil {
		t.Fatalf("tokens.Parse(tok) unexpected error: %v", err)
	}
	if parsedID != user.UserID {
		t.Errorf("login token sub = %v, want %v", parsedID, user.UserID)
	}
}

// ---------------------------------------------------------------------------
// Test: Login wrong password → ErrInvalidCredentials
// ---------------------------------------------------------------------------

// TestAuthService_Login_WrongPassword tests that Login with the wrong password
// returns the ErrInvalidCredentials sentinel (AC16).
func TestAuthService_Login_WrongPassword(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	username := uniqueUsername()
	password := "correct-password-123"

	user, _, err := h.svc.Signup(ctx, username, password)
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	_, err = h.svc.Login(ctx, username, "wrong-password-456")
	if err == nil {
		t.Fatal("Login() with wrong password expected error, got nil")
	}
	if !errors.Is(err, service.ErrInvalidCredentials) {
		t.Errorf("Login() error = %v, want errors.Is(_, ErrInvalidCredentials)", err)
	}
}

// ---------------------------------------------------------------------------
// Test: Login unknown username → same ErrInvalidCredentials (AC16)
// ---------------------------------------------------------------------------

// TestAuthService_Login_UnknownUsername tests that Login with an unknown username
// returns the IDENTICAL ErrInvalidCredentials sentinel as wrong-password (AC16).
func TestAuthService_Login_UnknownUsername(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	_, err := h.svc.Login(ctx, "no-such-user-"+uuid.NewString(), "any-password-123")
	if err == nil {
		t.Fatal("Login() with unknown username expected error, got nil")
	}
	if !errors.Is(err, service.ErrInvalidCredentials) {
		t.Errorf("Login() unknown user error = %v, want errors.Is(_, ErrInvalidCredentials)", err)
	}
}

// ---------------------------------------------------------------------------
// Test: Password policy boundaries (OQ-4)
// ---------------------------------------------------------------------------

// TestAuthService_Signup_PasswordPolicy tests all four OQ-4 boundary cases:
//
//   - 7-rune password  → ValidationError (< 8 runes)
//   - 8-rune password  → succeeds
//   - 72-byte password → succeeds
//   - 73-byte password → ValidationError (> 72 bytes)
//
// The validation error must be detectable via errors.As against ValidationError
// (the shape Task 9 handlers need to map it to HTTP 400).
func TestAuthService_Signup_PasswordPolicy(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	// 7 ASCII runes (7 bytes) — below minimum.
	pw7rune := "abcdefg" // len([]rune) == 7

	// 8 ASCII runes (8 bytes) — at minimum (must succeed).
	pw8rune := "abcdefgh" // len([]rune) == 8

	// 72-byte password (ASCII, so 72 runes too) — at maximum (must succeed).
	pw72byte := make([]byte, 72)
	for i := range pw72byte {
		pw72byte[i] = 'a'
	}

	// 73-byte password — above maximum.
	pw73byte := make([]byte, 73)
	for i := range pw73byte {
		pw73byte[i] = 'a'
	}

	tests := []struct {
		name       string
		password   string
		wantErr    bool
		wantValErr bool // errors.As(_, *ValidationError) must be true when wantErr=true
	}{
		{"7 runes — below min", pw7rune, true, true},
		{"8 runes — at min", pw8rune, false, false},
		{"72 bytes — at max", string(pw72byte), false, false},
		{"73 bytes — above max", string(pw73byte), true, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			username := uniqueUsername()
			user, _, err := h.svc.Signup(ctx, username, tt.password)

			if tt.wantErr {
				if err == nil {
					t.Fatalf("Signup() expected error, got nil (user: %v)", user)
				}
				if tt.wantValErr {
					var ve service.ValidationError
					if !errors.As(err, &ve) {
						t.Errorf("Signup() error = %v (%T), want errors.As(_, *ValidationError) to be true", err, err)
					}
				}
			} else {
				if err != nil {
					t.Fatalf("Signup() unexpected error: %v", err)
				}
				// Successful signup: register cleanup so rows don't linger.
				registerUserCleanup(t, h.pool, user.UserID)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Test: Signup duplicate username → store.ErrUsernameTaken
// ---------------------------------------------------------------------------

// TestAuthService_Signup_DuplicateUsername tests that signing up with an
// already-taken username propagates store.ErrUsernameTaken (AC14).
func TestAuthService_Signup_DuplicateUsername(t *testing.T) {
	h := newTestAuthService(t)
	ctx := context.Background()

	username := uniqueUsername()
	password := "first-password-123"

	user, _, err := h.svc.Signup(ctx, username, password)
	if err != nil {
		t.Fatalf("Signup() first call unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	_, _, err = h.svc.Signup(ctx, username, "second-password-456")
	if err == nil {
		t.Fatal("Signup() with duplicate username expected error, got nil")
	}
	if !errors.Is(err, store.ErrUsernameTaken) {
		t.Errorf("Signup() duplicate error = %v, want errors.Is(_, store.ErrUsernameTaken)", err)
	}
}

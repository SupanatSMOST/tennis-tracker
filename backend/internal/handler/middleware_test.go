package handler

// Integration tests for RequireAuth middleware (Task 10).
//
// These tests hit a real Postgres cluster (DATABASE_URL env var, port 55432).
// They t.Skip when DATABASE_URL is not set so the suite remains CI-safe.
// All rows inserted are cleaned up via t.Cleanup; no truncation.

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Supanat-Smost/tennis/backend/internal/model"
	"github.com/Supanat-Smost/tennis/backend/internal/service"
	"github.com/Supanat-Smost/tennis/backend/internal/store"
)

// ── test-local helpers ───────────────────────────────────────────────────────

// mwBuildPool opens a pgxpool from DATABASE_URL or skips the test.
func mwBuildPool(t *testing.T) *pgxpool.Pool {
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

// mwUniqueUsername returns a unique username per test run.
func mwUniqueUsername(base string) string {
	return fmt.Sprintf("%s_%s", base, uuid.New().String()[:8])
}

// mwCleanupUser deletes profile then user_login rows in FK order.
func mwCleanupUser(t *testing.T, pool *pgxpool.Pool, userID uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `DELETE FROM profile WHERE user_id = $1`, userID); err != nil {
		t.Logf("cleanup profile %s: %v", userID, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM user_login WHERE user_id = $1`, userID); err != nil {
		t.Logf("cleanup user_login %s: %v", userID, err)
	}
}

// mwCreateUser inserts a minimal user_login + profile row and registers cleanup.
func mwCreateUser(t *testing.T, pool *pgxpool.Pool, s *store.Store) model.User {
	t.Helper()
	u := model.User{
		UserID:       uuid.New(),
		Username:     mwUniqueUsername("mwuser"),
		PasswordHash: "$2a$12$fakehashformiddlewaretest",
	}
	if err := s.CreateUserWithProfile(context.Background(), u); err != nil {
		t.Fatalf("mwCreateUser: CreateUserWithProfile: %v", err)
	}
	t.Cleanup(func() { mwCleanupUser(t, pool, u.UserID) })
	return u
}

// mwBuildAlgNoneToken builds a token with alg:none for the given UUID.
func mwBuildAlgNoneToken(t *testing.T, id uuid.UUID) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodNone, jwt.MapClaims{
		"sub": id.String(),
	})
	s, err := tok.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("build alg:none token: %v", err)
	}
	return s
}

// mwBuildWrongKeyToken builds a valid HS256 token signed with a different key.
func mwBuildWrongKeyToken(t *testing.T, id uuid.UUID) string {
	t.Helper()
	otherKey := []byte("wrong-key-for-middleware-test-xxxx")
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": id.String(),
	})
	s, err := tok.SignedString(otherKey)
	if err != nil {
		t.Fatalf("build wrong-key token: %v", err)
	}
	return s
}

// mwBuildRS256Token builds an RS256-signed token (algorithm confusion attack).
func mwBuildRS256Token(t *testing.T, id uuid.UUID) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"sub": id.String(),
	})
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("build RS256 token: %v", err)
	}
	return s
}

// mwApply wraps a stub handler with RequireAuth and records whether the stub ran
// and what AuthedUser it received.
type mwResult struct {
	ran  bool
	user AuthedUser
}

func mwApply(tokens *service.TokenService, s *store.Store, res *mwResult) http.Handler {
	stub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		res.ran = true
		res.user, _ = userFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	return RequireAuth(tokens, s)(stub)
}

// ── test key used across all cases ───────────────────────────────────────────

var mwTestKey = []byte("middleware-test-signing-key-2026")

// ── AC19 + header-parsing cases (no DB needed for 401 paths) ─────────────────

// TestRequireAuth_MissingHeader verifies that a request with no Authorization
// header returns 401 {"error":"unauthorized"}.
func TestRequireAuth_MissingHeader(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_BasicScheme verifies that "Basic xxx" (non-Bearer) → 401.
func TestRequireAuth_BasicScheme(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Basic dXNlcjpwYXNz")
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_BearerWithoutToken verifies that "Bearer" with no following
// token (no space separator at all) → 401.
func TestRequireAuth_BearerWithoutToken(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer")
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_BearerEmptyToken verifies that "Bearer " (space but empty
// token string) → 401. This exercises the token=="" branch after strings.Cut.
func TestRequireAuth_BearerEmptyToken(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer ")
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_WrongKey verifies AC19: a token signed with a different key
// is rejected with 401.
func TestRequireAuth_WrongKey(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	wrongKeyTok := mwBuildWrongKeyToken(t, uuid.New())

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+wrongKeyTok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_AlgNone verifies AC19: an alg:none token is rejected.
func TestRequireAuth_AlgNone(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	algNoneTok := mwBuildAlgNoneToken(t, uuid.New())

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+algNoneTok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_RS256AlgorithmConfusion verifies AC19: an RS256-signed token
// is rejected (algorithm confusion / alg-swap attack).
func TestRequireAuth_RS256AlgorithmConfusion(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	rs256Tok := mwBuildRS256Token(t, uuid.New())

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+rs256Tok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// TestRequireAuth_MalformedToken verifies AC19: a garbage string is rejected.
func TestRequireAuth_MalformedToken(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer this.is.not.a.jwt.token")
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// ── AC20: valid token, user not in DB ────────────────────────────────────────

// TestRequireAuth_UnknownSubject verifies AC20: a correctly-signed token whose
// sub UUID does not exist in user_login returns 401.
func TestRequireAuth_UnknownSubject(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	// Issue a token for a UUID that was never inserted.
	ghostID := uuid.New()
	tok, err := tokens.Issue(ghostID)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// ── Happy path: valid token for existing user → 200 + context populated ──────

// TestRequireAuth_ValidToken verifies AC18/AC19/AC20 success path: a valid,
// correctly-signed token for an existing user_login row results in:
//   - HTTP 200
//   - stub next-handler ran
//   - context carries AuthedUser with correct UserID and Username
func TestRequireAuth_ValidToken(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	// Insert a real user row (cleaned up by mwCreateUser).
	u := mwCreateUser(t, pool, s)

	tok, err := tokens.Issue(u.UserID)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
	if !res.ran {
		t.Error("stub next-handler did not run; RequireAuth should have called it")
	}
	if res.user.UserID != u.UserID {
		t.Errorf("AuthedUser.UserID = %v, want %v", res.user.UserID, u.UserID)
	}
	if res.user.Username != u.Username {
		t.Errorf("AuthedUser.Username = %q, want %q", res.user.Username, u.Username)
	}
}

// ── AC20 delete-then-use path ─────────────────────────────────────────────────

// TestRequireAuth_DeletedUser verifies AC20 via create-then-delete: a token
// issued before the user row was deleted is rejected after deletion.
func TestRequireAuth_DeletedUser(t *testing.T) {
	pool := mwBuildPool(t)
	s := store.New(pool)
	tokens := service.NewTokenService(mwTestKey)
	var res mwResult

	// Create user, issue token, then delete the row.
	u := mwCreateUser(t, pool, s)
	tok, err := tokens.Issue(u.UserID)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	// Delete now (mwCreateUser also registers cleanup, which is idempotent).
	mwCleanupUser(t, pool, u.UserID)

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	mwApply(tokens, s, &res).ServeHTTP(rec, req)

	assertUnauthorized(t, rec, res.ran)
}

// ── assertion helper ─────────────────────────────────────────────────────────

// assertUnauthorized checks status 401, exact body, and that the stub did not run.
func assertUnauthorized(t *testing.T, rec *httptest.ResponseRecorder, stubRan bool) {
	t.Helper()
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
	const wantBody = `{"error":"unauthorized"}`
	if got := rec.Body.String(); got != wantBody {
		t.Errorf("body = %q, want %q", got, wantBody)
	}
	if stubRan {
		t.Error("stub next-handler ran; it must not be called on 401 path")
	}
}

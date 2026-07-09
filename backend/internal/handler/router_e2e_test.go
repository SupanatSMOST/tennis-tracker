package handler_test

// End-to-end tests for Task 12: full server wiring through BuildRouter.
//
// These tests boot the real router (real pgxpool → real Store → real
// TokenService → real AuthService → real AuthHandler → BuildRouter) and drive
// actual HTTP requests via httptest.NewServer.  No mocking anywhere.
//
// Requirements: DATABASE_URL env var must point to the throwaway Postgres
// cluster on port 55432 (already migrated).  Tests t.Skip when the var is
// absent so the suite stays CI-safe without a DB.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/handler"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// ── helpers ──────────────────────────────────────────────────────────────────

// e2eBuildServer constructs the full dependency graph exactly as main.go does,
// wraps it in httptest.NewServer, and returns the server + pool.
// The pool and server are closed via t.Cleanup (server first, pool last).
func e2eBuildServer(t *testing.T, signingKey []byte) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping E2E integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("e2eBuildServer: pgxpool.New: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Fatalf("e2eBuildServer: pool.Ping: %v", err)
	}

	st := store.New(pool)
	tokens := service.NewTokenService(signingKey)
	authSvc := service.NewAuthService(st, tokens)
	authH := handler.NewAuthHandler(authSvc)
	router := handler.BuildRouter(authH, tokens, st)

	srv := httptest.NewServer(router)

	// Cleanup: server.Close then pool.Close (registered LIFO — pool closes last).
	t.Cleanup(pool.Close)
	t.Cleanup(srv.Close)

	return srv, pool
}

// e2eUniqueUsername returns a unique test username on every call.
func e2eUniqueUsername(base string) string {
	return fmt.Sprintf("%s_%s", base, uuid.New().String()[:8])
}

// e2eCleanupUser deletes the profile row then user_login row by user_id.
// Registered via t.Cleanup so it runs even when the test fails.
func e2eCleanupUser(t *testing.T, pool *pgxpool.Pool, userID string) {
	t.Helper()
	id, err := uuid.Parse(userID)
	if err != nil {
		t.Logf("e2eCleanupUser: bad uuid %q: %v", userID, err)
		return
	}
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `DELETE FROM profile WHERE user_id = $1`, id); err != nil {
		t.Logf("e2eCleanupUser: delete profile %s: %v", id, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM user_login WHERE user_id = $1`, id); err != nil {
		t.Logf("e2eCleanupUser: delete user_login %s: %v", id, err)
	}
}

// e2ePost sends a POST request with a JSON body string and returns the response.
func e2ePost(t *testing.T, srv *httptest.Server, path, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("e2ePost: NewRequest: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("e2ePost: Do: %v", err)
	}
	return resp
}

// e2eGet sends a GET request, optionally with an Authorization header.
func e2eGet(t *testing.T, srv *httptest.Server, path, authHeader string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, srv.URL+path, nil)
	if err != nil {
		t.Fatalf("e2eGet: NewRequest: %v", err)
	}
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("e2eGet: Do: %v", err)
	}
	return resp
}

// decodeJSON decodes the response body into target and closes the body.
func decodeJSON(t *testing.T, resp *http.Response, target any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(target); err != nil {
		t.Fatalf("decodeJSON: %v", err)
	}
}

// ── tests ────────────────────────────────────────────────────────────────────

var testSigningKey = []byte("e2e-test-signing-key-minimum-32-chars!!")

// TestRouter_Health verifies AC12: GET /health → 200 {"status":"ok"}.
// It also confirms health is unauthenticated (no token required).
func TestRouter_Health(t *testing.T) {
	srv, _ := e2eBuildServer(t, testSigningKey)

	resp := e2eGet(t, srv, "/health", "")
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /health: want 200, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("GET /health: decode body: %v", err)
	}
	if got := body["status"]; got != "ok" {
		t.Errorf("GET /health: body.status = %q, want %q", got, "ok")
	}
}

// TestRouter_SignupLoginMe is the main E2E flow exercising AC13, AC15, AC18:
//   - POST /auth/signup (unique user) → 201, {user_id, username, token}
//   - POST /auth/login (same creds)   → 200, {token} with valid JWT
//   - GET  /me with that token         → 200, {user_id, username} matching signup
func TestRouter_SignupLoginMe(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	username := e2eUniqueUsername("e2euser")
	password := "securepassword123"
	body := fmt.Sprintf(`{"username":%q,"password":%q}`, username, password)

	// ── signup ────────────────────────────────────────────────────────────────
	signupResp := e2ePost(t, srv, "/auth/signup", body)
	if signupResp.StatusCode != http.StatusCreated {
		t.Fatalf("POST /auth/signup: want 201, got %d", signupResp.StatusCode)
	}

	var signupBody struct {
		UserID   string `json:"user_id"`
		Username string `json:"username"`
		Token    string `json:"token"`
	}
	decodeJSON(t, signupResp, &signupBody)

	if signupBody.UserID == "" {
		t.Fatal("POST /auth/signup: user_id is empty")
	}
	if signupBody.Username != username {
		t.Errorf("POST /auth/signup: username = %q, want %q", signupBody.Username, username)
	}
	if signupBody.Token == "" {
		t.Fatal("POST /auth/signup: token is empty")
	}
	// Register cleanup ASAP so partial failures still clean up.
	t.Cleanup(func() { e2eCleanupUser(t, pool, signupBody.UserID) })

	// ── login ─────────────────────────────────────────────────────────────────
	loginResp := e2ePost(t, srv, "/auth/login", body)
	if loginResp.StatusCode != http.StatusOK {
		t.Fatalf("POST /auth/login: want 200, got %d", loginResp.StatusCode)
	}

	var loginBody struct {
		Token string `json:"token"`
	}
	decodeJSON(t, loginResp, &loginBody)

	if loginBody.Token == "" {
		t.Fatal("POST /auth/login: token is empty")
	}

	// AC15: JWT sub = user_id, no exp claim.
	parsed, _, err := new(jwt.Parser).ParseUnverified(loginBody.Token, jwt.MapClaims{})
	if err != nil {
		t.Fatalf("parse login token: %v", err)
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		t.Fatal("login token claims are not MapClaims")
	}
	sub, _ := claims["sub"].(string)
	if sub != signupBody.UserID {
		t.Errorf("login token sub = %q, want %q", sub, signupBody.UserID)
	}
	if _, hasExp := claims["exp"]; hasExp {
		t.Error("login token must not contain an 'exp' claim (AC15)")
	}

	// ── GET /me with valid token (AC18) ───────────────────────────────────────
	meResp := e2eGet(t, srv, "/me", "Bearer "+loginBody.Token)
	if meResp.StatusCode != http.StatusOK {
		t.Fatalf("GET /me (valid token): want 200, got %d", meResp.StatusCode)
	}

	var meBody struct {
		UserID   string `json:"user_id"`
		Username string `json:"username"`
	}
	decodeJSON(t, meResp, &meBody)

	if meBody.UserID != signupBody.UserID {
		t.Errorf("GET /me: user_id = %q, want %q", meBody.UserID, signupBody.UserID)
	}
	if meBody.Username != username {
		t.Errorf("GET /me: username = %q, want %q", meBody.Username, username)
	}
}

// TestRouter_MeBadToken verifies AC19:
// GET /me with a token signed by a DIFFERENT key → 401.
func TestRouter_MeBadToken(t *testing.T) {
	srv, _ := e2eBuildServer(t, testSigningKey)

	// Token signed with a completely different key.
	differentKey := []byte("different-signing-key-minimum-32-chars!!")
	differentTokens := service.NewTokenService(differentKey)
	badToken, err := differentTokens.Issue(uuid.New())
	if err != nil {
		t.Fatalf("Issue bad token: %v", err)
	}

	resp := e2eGet(t, srv, "/me", "Bearer "+badToken)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("GET /me (wrong-key token): want 401, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("GET /me bad token: decode body: %v", err)
	}
	if body["error"] != "unauthorized" {
		t.Errorf("GET /me bad token: error = %q, want %q", body["error"], "unauthorized")
	}
}

// TestRouter_MeNoToken verifies AC19:
// GET /me with NO Authorization header → 401.
func TestRouter_MeNoToken(t *testing.T) {
	srv, _ := e2eBuildServer(t, testSigningKey)

	resp := e2eGet(t, srv, "/me", "")
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("GET /me (no token): want 401, got %d", resp.StatusCode)
	}
}

// TestRouter_HealthNoToken confirms routing sanity: GET /health does NOT go
// through RequireAuth (returns 200 even without a token), while GET /me does.
func TestRouter_HealthNoToken(t *testing.T) {
	srv, _ := e2eBuildServer(t, testSigningKey)

	healthResp := e2eGet(t, srv, "/health", "")
	defer healthResp.Body.Close()
	if healthResp.StatusCode != http.StatusOK {
		t.Errorf("GET /health (no token): want 200, got %d", healthResp.StatusCode)
	}

	meResp := e2eGet(t, srv, "/me", "")
	defer meResp.Body.Close()
	if meResp.StatusCode != http.StatusUnauthorized {
		t.Errorf("GET /me (no token): want 401, got %d", meResp.StatusCode)
	}
}

// TestRouter_SignupDuplicateUsername verifies AC14:
// A second signup with the same username → 409 {"error":"username already taken"}.
func TestRouter_SignupDuplicateUsername(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	username := e2eUniqueUsername("dupuser")
	password := "validpassword99"
	body := fmt.Sprintf(`{"username":%q,"password":%q}`, username, password)

	// First signup — should succeed.
	first := e2ePost(t, srv, "/auth/signup", body)
	if first.StatusCode != http.StatusCreated {
		t.Fatalf("first signup: want 201, got %d", first.StatusCode)
	}
	var firstBody struct {
		UserID string `json:"user_id"`
	}
	decodeJSON(t, first, &firstBody)
	t.Cleanup(func() { e2eCleanupUser(t, pool, firstBody.UserID) })

	// Second signup with same username — must be 409.
	second := e2ePost(t, srv, "/auth/signup", body)
	defer second.Body.Close()
	if second.StatusCode != http.StatusConflict {
		t.Errorf("duplicate signup: want 409, got %d", second.StatusCode)
	}

	var errBody map[string]string
	if err := json.NewDecoder(second.Body).Decode(&errBody); err != nil {
		t.Fatalf("duplicate signup: decode body: %v", err)
	}
	if errBody["error"] != "username already taken" {
		t.Errorf("duplicate signup: error = %q, want %q", errBody["error"], "username already taken")
	}
}

// TestRouter_LoginInvalidCredentials verifies AC16:
// Wrong password → 401 indistinguishable from unknown username.
func TestRouter_LoginInvalidCredentials(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	username := e2eUniqueUsername("creduser")
	password := "correctpassword1"

	// Create the user first.
	signupBody := fmt.Sprintf(`{"username":%q,"password":%q}`, username, password)
	signupResp := e2ePost(t, srv, "/auth/signup", signupBody)
	if signupResp.StatusCode != http.StatusCreated {
		t.Fatalf("setup signup: want 201, got %d", signupResp.StatusCode)
	}
	var su struct {
		UserID string `json:"user_id"`
	}
	decodeJSON(t, signupResp, &su)
	t.Cleanup(func() { e2eCleanupUser(t, pool, su.UserID) })

	tests := []struct {
		name     string
		username string
		password string
	}{
		{"wrong password", username, "wrongpassword!!"},
		{"unknown username", e2eUniqueUsername("ghost"), "doesnotmatter"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := fmt.Sprintf(`{"username":%q,"password":%q}`, tt.username, tt.password)
			resp := e2ePost(t, srv, "/auth/login", body)
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusUnauthorized {
				t.Errorf("login %q: want 401, got %d", tt.name, resp.StatusCode)
			}

			var errBody map[string]string
			if err := json.NewDecoder(resp.Body).Decode(&errBody); err != nil {
				t.Fatalf("login %q: decode body: %v", tt.name, err)
			}
			if errBody["error"] != "invalid credentials" {
				t.Errorf("login %q: error = %q, want %q", tt.name, errBody["error"], "invalid credentials")
			}
		})
	}
}

// TestRouter_WrongMethodOnHealth tests routing sanity: Go 1.22 method+pattern
// routing returns 405 when the method does not match a registered pattern.
func TestRouter_WrongMethodOnHealth(t *testing.T) {
	srv, _ := e2eBuildServer(t, testSigningKey)

	req, err := http.NewRequest(http.MethodPost, srv.URL+"/health", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST /health: want 405, got %d", resp.StatusCode)
	}
}

package handler_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/handler"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// handlerTestHarness holds the real stack used by all handler tests.
type handlerTestHarness struct {
	authHandler *handler.AuthHandler
	tokens      *service.TokenService
	pool        *pgxpool.Pool
}

// newHandlerHarness builds a real AuthHandler backed by the Postgres cluster at
// DATABASE_URL. The test is skipped if DATABASE_URL is unset; it fails loudly
// if DATABASE_URL is set but unreachable.
func newHandlerHarness(t *testing.T) handlerTestHarness {
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
	tok := service.NewTokenService([]byte("test-signing-key-for-handler-tests"))
	svc := service.NewAuthService(st, tok)

	return handlerTestHarness{
		authHandler: handler.NewAuthHandler(svc),
		tokens:      tok,
		pool:        pool,
	}
}

// uniqueUsername returns a username that is unique per test run (uuid-based).
func uniqueUsername() string {
	return "h_" + uuid.NewString()
}

// registerUserCleanup registers a t.Cleanup that removes profile then user_login
// rows for the given userID (FK-ordered: profile before user_login).
func registerUserCleanup(t *testing.T, pool *pgxpool.Pool, userID uuid.UUID) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		pool.Exec(ctx, "DELETE FROM profile WHERE user_id = $1", userID)    //nolint:errcheck
		pool.Exec(ctx, "DELETE FROM user_login WHERE user_id = $1", userID) //nolint:errcheck
	})
}

// doSignup sends a POST /auth/signup request with the given body and returns the
// ResponseRecorder. If pool is non-nil and the response is 201, it also registers
// user cleanup using the user_id from the response body.
func doSignup(t *testing.T, h handlerTestHarness, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/auth/signup", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.authHandler.Signup(rec, req)
	return rec
}

// doLogin sends a POST /auth/login request with the given body.
func doLogin(t *testing.T, h handlerTestHarness, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.authHandler.Login(rec, req)
	return rec
}

// ---------------------------------------------------------------------------
// Health handler tests
// ---------------------------------------------------------------------------

// TestHealth_Status200_BodyOK verifies AC12: GET /health → 200 {"status":"ok"}.
func TestHealth_Status200_BodyOK(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	handler.Health(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("Health() status = %d, want 200", rec.Code)
	}

	got := rec.Body.String()
	want := `{"status":"ok"}`
	if got != want {
		t.Errorf("Health() body = %q, want %q", got, want)
	}

	ct := rec.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Health() Content-Type = %q, want application/json", ct)
	}
}

// TestHealth_NoDBProbe verifies that Health returns 200 even with no database
// available (pure liveness — OQ-3). No DATABASE_URL needed for this test.
func TestHealth_NoDBProbe(t *testing.T) {
	// Deliberately not constructing any DB pool. Health must not touch the DB.
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	handler.Health(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("Health() status = %d, want 200 (no DB probe expected)", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// Signup handler tests
// ---------------------------------------------------------------------------

// TestSignupHandler_HappyPath verifies AC13 + OQ-2: signup returns 201 with
// user_id (valid UUID), username, and a non-empty token that parses to the user UUID.
func TestSignupHandler_HappyPath(t *testing.T) {
	h := newHandlerHarness(t)

	username := uniqueUsername()
	body := `{"username":"` + username + `","password":"strongpass1"}`

	rec := doSignup(t, h, body)

	if rec.Code != http.StatusCreated {
		t.Fatalf("Signup() status = %d, want 201; body: %s", rec.Code, rec.Body.String())
	}

	// Decode response into a raw map so we can assert keys exactly.
	var resp map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("Signup() could not unmarshal response: %v", err)
	}

	// Assert the exact key set: {user_id, username, token} — no extra fields.
	wantKeys := map[string]bool{"user_id": true, "username": true, "token": true}
	for k := range resp {
		if !wantKeys[k] {
			t.Errorf("Signup() response has unexpected key %q", k)
		}
		delete(wantKeys, k)
	}
	for missing := range wantKeys {
		t.Errorf("Signup() response missing key %q", missing)
	}

	// user_id must be a valid UUID.
	var userIDStr string
	if err := json.Unmarshal(resp["user_id"], &userIDStr); err != nil {
		t.Fatalf("Signup() user_id not a string: %v", err)
	}
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		t.Errorf("Signup() user_id = %q, not a valid UUID: %v", userIDStr, err)
	}
	registerUserCleanup(t, h.pool, userID)

	// username must match what was sent.
	var gotUsername string
	if err := json.Unmarshal(resp["username"], &gotUsername); err != nil {
		t.Fatalf("Signup() username not a string: %v", err)
	}
	if gotUsername != username {
		t.Errorf("Signup() username = %q, want %q", gotUsername, username)
	}

	// token must be non-empty and parse back to the same UUID.
	var tokenStr string
	if err := json.Unmarshal(resp["token"], &tokenStr); err != nil {
		t.Fatalf("Signup() token not a string: %v", err)
	}
	if tokenStr == "" {
		t.Fatal("Signup() token is empty")
	}
	parsedID, err := h.tokens.Parse(tokenStr)
	if err != nil {
		t.Fatalf("Signup() token.Parse: %v", err)
	}
	if parsedID != userID {
		t.Errorf("Signup() token sub = %v, want %v", parsedID, userID)
	}
}

// TestSignupHandler_DuplicateUsername verifies AC14: duplicate signup → 409
// with exactly {"error":"username already taken"}.
func TestSignupHandler_DuplicateUsername(t *testing.T) {
	h := newHandlerHarness(t)

	username := uniqueUsername()
	body := `{"username":"` + username + `","password":"strongpass1"}`

	// First signup — must succeed.
	rec1 := doSignup(t, h, body)
	if rec1.Code != http.StatusCreated {
		t.Fatalf("first Signup() status = %d, want 201; body: %s", rec1.Code, rec1.Body.String())
	}
	// Register cleanup for the first user.
	var resp1 map[string]json.RawMessage
	if err := json.Unmarshal(rec1.Body.Bytes(), &resp1); err == nil {
		var idStr string
		if err := json.Unmarshal(resp1["user_id"], &idStr); err == nil {
			if uid, err := uuid.Parse(idStr); err == nil {
				registerUserCleanup(t, h.pool, uid)
			}
		}
	}

	// Second signup with same username — must return 409.
	rec2 := doSignup(t, h, body)
	if rec2.Code != http.StatusConflict {
		t.Errorf("duplicate Signup() status = %d, want 409", rec2.Code)
	}

	wantBody := `{"error":"username already taken"}`
	got := rec2.Body.String()
	if got != wantBody {
		t.Errorf("duplicate Signup() body = %q, want %q", got, wantBody)
	}
}

// TestSignupHandler_PasswordTooShort verifies OQ-4: password of 7 runes → 400.
func TestSignupHandler_PasswordTooShort(t *testing.T) {
	h := newHandlerHarness(t)

	body := `{"username":"` + uniqueUsername() + `","password":"abc1234"}` // 7 chars
	rec := doSignup(t, h, body)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Signup(7-char pw) status = %d, want 400", rec.Code)
	}

	// Body must be {"error":"..."}
	var errResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("Signup(7-char pw) response not valid JSON: %v", err)
	}
	if _, hasError := errResp["error"]; !hasError {
		t.Errorf("Signup(7-char pw) response has no 'error' field, body = %q", rec.Body.String())
	}
}

// TestSignupHandler_PasswordTooLong verifies OQ-4: password of 73 bytes → 400.
func TestSignupHandler_PasswordTooLong(t *testing.T) {
	h := newHandlerHarness(t)

	pw73 := strings.Repeat("a", 73)
	body := `{"username":"` + uniqueUsername() + `","password":"` + pw73 + `"}`
	rec := doSignup(t, h, body)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Signup(73-byte pw) status = %d, want 400", rec.Code)
	}

	var errResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("Signup(73-byte pw) response not valid JSON: %v", err)
	}
	if _, hasError := errResp["error"]; !hasError {
		t.Errorf("Signup(73-byte pw) response has no 'error' field, body = %q", rec.Body.String())
	}
}

// TestSignupHandler_MalformedJSON verifies that malformed JSON body → 400.
func TestSignupHandler_MalformedJSON(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doSignup(t, h, `{bad json`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Signup(malformed JSON) status = %d, want 400", rec.Code)
	}
}

// TestSignupHandler_EmptyUsername verifies that empty username field → 400.
func TestSignupHandler_EmptyUsername(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doSignup(t, h, `{"username":"","password":"strongpass1"}`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Signup(empty username) status = %d, want 400", rec.Code)
	}
}

// TestSignupHandler_EmptyPassword verifies that empty password field → 400.
func TestSignupHandler_EmptyPassword(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doSignup(t, h, `{"username":"`+uniqueUsername()+`","password":""}`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Signup(empty password) status = %d, want 400", rec.Code)
	}
}

// ---------------------------------------------------------------------------
// Login handler tests
// ---------------------------------------------------------------------------

// TestLoginHandler_HappyPath verifies AC15: login after signup → 200 {"token":"<jwt>"}
// where the token parses back to the user UUID.
func TestLoginHandler_HappyPath(t *testing.T) {
	h := newHandlerHarness(t)

	username := uniqueUsername()
	password := "logintest-pass1"

	// Signup first to create the user.
	signupBody := `{"username":"` + username + `","password":"` + password + `"}`
	recSignup := doSignup(t, h, signupBody)
	if recSignup.Code != http.StatusCreated {
		t.Fatalf("Signup() status = %d, want 201; body: %s", recSignup.Code, recSignup.Body.String())
	}

	var signupResp map[string]json.RawMessage
	if err := json.Unmarshal(recSignup.Body.Bytes(), &signupResp); err != nil {
		t.Fatalf("Signup() unmarshal: %v", err)
	}
	var userIDStr string
	json.Unmarshal(signupResp["user_id"], &userIDStr) //nolint:errcheck
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		t.Fatalf("Signup() user_id not a UUID: %v", err)
	}
	registerUserCleanup(t, h.pool, userID)

	// Login.
	loginBody := `{"username":"` + username + `","password":"` + password + `"}`
	recLogin := doLogin(t, h, loginBody)

	if recLogin.Code != http.StatusOK {
		t.Fatalf("Login() status = %d, want 200; body: %s", recLogin.Code, recLogin.Body.String())
	}

	// Assert key set is exactly {token}.
	var resp map[string]json.RawMessage
	if err := json.Unmarshal(recLogin.Body.Bytes(), &resp); err != nil {
		t.Fatalf("Login() unmarshal: %v", err)
	}
	for k := range resp {
		if k != "token" {
			t.Errorf("Login() response has unexpected key %q", k)
		}
	}
	if _, ok := resp["token"]; !ok {
		t.Fatal("Login() response missing 'token' key")
	}

	// Token must parse to the same user UUID.
	var tokenStr string
	if err := json.Unmarshal(resp["token"], &tokenStr); err != nil {
		t.Fatalf("Login() token not a string: %v", err)
	}
	if tokenStr == "" {
		t.Fatal("Login() token is empty")
	}
	parsedID, err := h.tokens.Parse(tokenStr)
	if err != nil {
		t.Fatalf("Login() token.Parse: %v", err)
	}
	if parsedID != userID {
		t.Errorf("Login() token sub = %v, want %v", parsedID, userID)
	}
}

// TestLoginHandler_WrongPassword verifies AC16: wrong password → 401
// with exactly {"error":"invalid credentials"}.
func TestLoginHandler_WrongPassword(t *testing.T) {
	h := newHandlerHarness(t)

	username := uniqueUsername()

	recSignup := doSignup(t, h, `{"username":"`+username+`","password":"correctpass1"}`)
	if recSignup.Code != http.StatusCreated {
		t.Fatalf("Signup() status = %d; body: %s", recSignup.Code, recSignup.Body.String())
	}
	var s1 map[string]json.RawMessage
	json.Unmarshal(recSignup.Body.Bytes(), &s1) //nolint:errcheck
	var idStr string
	json.Unmarshal(s1["user_id"], &idStr) //nolint:errcheck
	if uid, err := uuid.Parse(idStr); err == nil {
		registerUserCleanup(t, h.pool, uid)
	}

	rec := doLogin(t, h, `{"username":"`+username+`","password":"wrongpassword1"}`)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("Login(wrong password) status = %d, want 401", rec.Code)
	}

	wantBody := `{"error":"invalid credentials"}`
	got := rec.Body.String()
	if got != wantBody {
		t.Errorf("Login(wrong password) body = %q, want %q", got, wantBody)
	}
}

// TestLoginHandler_UnknownUsername verifies AC16: unknown username → 401
// with exactly the SAME body as wrong password (no account-existence leak).
func TestLoginHandler_UnknownUsername(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doLogin(t, h, `{"username":"no-such-user-`+uuid.NewString()+`","password":"somepassword1"}`)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("Login(unknown user) status = %d, want 401", rec.Code)
	}

	wantBody := `{"error":"invalid credentials"}`
	got := rec.Body.String()
	if got != wantBody {
		t.Errorf("Login(unknown user) body = %q, want %q", got, wantBody)
	}
}

// TestLoginHandler_MalformedJSON verifies that malformed JSON body → 400.
func TestLoginHandler_MalformedJSON(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doLogin(t, h, `{bad json`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Login(malformed JSON) status = %d, want 400", rec.Code)
	}
}

// TestLoginHandler_EmptyUsername verifies that empty username field → 400.
func TestLoginHandler_EmptyUsername(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doLogin(t, h, `{"username":"","password":"somepassword1"}`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Login(empty username) status = %d, want 400", rec.Code)
	}
}

// TestLoginHandler_EmptyPassword verifies that empty password field → 400.
func TestLoginHandler_EmptyPassword(t *testing.T) {
	h := newHandlerHarness(t)

	rec := doLogin(t, h, `{"username":"`+uniqueUsername()+`","password":""}`)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("Login(empty password) status = %d, want 400", rec.Code)
	}
}

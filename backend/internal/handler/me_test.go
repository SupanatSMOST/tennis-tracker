package handler

// Unit tests for the Me handler (Task 11, AC18).
//
// Context injection approach: package-internal (white-box). Since this file is
// in package handler, it can use the unexported authedUserKey type and the
// userFromContext helper directly — the same path the real RequireAuth
// middleware takes. No DB is needed; Me reads only from the request context.

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
)

// TestMe_HappyPath verifies AC18: when the request context carries an
// AuthedUser, Me returns 200 and exactly {"user_id":"<uuid>","username":"<name>"}.
// It also confirms Me makes no DB calls (no store field on the handler — structural guarantee).
func TestMe_HappyPath(t *testing.T) {
	id := uuid.MustParse("11111111-2222-3333-4444-555555555555")
	authed := AuthedUser{UserID: id, Username: "alice"}

	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	req = req.WithContext(
		// Inject via the same unexported key the middleware uses (package-internal access).
		context.WithValue(req.Context(), authedUserKey{}, authed),
	)
	rec := httptest.NewRecorder()

	Me(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}

	wantBody := fmt.Sprintf(`{"user_id":"%s","username":"alice"}`, id.String())
	if got := rec.Body.String(); got != wantBody {
		t.Errorf("body = %q, want %q", got, wantBody)
	}

	wantCT := "application/json"
	if got := rec.Header().Get("Content-Type"); got != wantCT {
		t.Errorf("Content-Type = %q, want %q", got, wantCT)
	}
}

// TestMe_MissingContext verifies the defensive guard: when no AuthedUser is in
// context (misconfigured route — RequireAuth not applied), Me returns 401
// {"error":"unauthorized"} and does not panic.
func TestMe_MissingContext(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/me", nil)
	// No AuthedUser injected — empty context.
	rec := httptest.NewRecorder()

	Me(rec, req)

	// Reuse the existing package-level helper from middleware_test.go.
	// stubRan=false because Me is the terminal handler (no next).
	assertUnauthorized(t, rec, false)
}

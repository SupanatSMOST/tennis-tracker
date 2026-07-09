package handler

import (
	"net/http"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// BuildRouter constructs a ServeMux with all four routes registered.
//
// Routes:
//   - GET  /health       — pure liveness, no DB probe (OQ-3)
//   - POST /auth/signup  — create account + auto-login (OQ-2)
//   - POST /auth/login   — credential exchange
//   - GET  /me           — protected; wrapped in RequireAuth middleware
//
// Go 1.22+ ServeMux method+pattern routing is used; no external router needed.
func BuildRouter(authH *AuthHandler, tokens *service.TokenService, s *store.Store) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", Health)
	mux.HandleFunc("POST /auth/signup", authH.Signup)
	mux.HandleFunc("POST /auth/login", authH.Login)
	// RequireAuth(…)(…) returns http.Handler, so use Handle (not HandleFunc).
	mux.Handle("GET /me", RequireAuth(tokens, s)(http.HandlerFunc(Me)))

	return mux
}

package handler

import (
	"net/http"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// BuildRouter constructs a ServeMux with all routes registered.
//
// Routes:
//   - GET  /health                   — pure liveness, no DB probe (OQ-3)
//   - POST /auth/signup              — create account + auto-login (OQ-2)
//   - POST /auth/login               — credential exchange
//   - GET  /me                       — protected; wrapped in RequireAuth middleware
//   - POST /matches                  — create match (RequireAuth)
//   - GET  /matches                  — list caller's matches (RequireAuth)
//   - GET  /matches/{id}             — get owned match (RequireAuth)
//   - POST /matches/{id}/end         — end match (RequireAuth)
//   - POST /matches/{id}/records     — batch add shots (RequireAuth)
//   - GET  /matches/{id}/records     — list shots (RequireAuth)
//   - GET  /matches/{id}/summary     — read shot summary (RequireAuth)
//
// Go 1.22+ ServeMux method+pattern routing is used; no external router needed.
func BuildRouter(authH *AuthHandler, gameplayH *GameplayHandler, tokens *service.TokenService, s *store.Store) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", Health)
	mux.HandleFunc("POST /auth/signup", authH.Signup)
	mux.HandleFunc("POST /auth/login", authH.Login)
	// RequireAuth(…)(…) returns http.Handler, so use Handle (not HandleFunc).
	mux.Handle("GET /me", RequireAuth(tokens, s)(http.HandlerFunc(Me)))

	// Gameplay routes — all protected by RequireAuth.
	mux.Handle("POST /matches", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.CreateMatch)))
	mux.Handle("GET /matches", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.ListMatches)))
	mux.Handle("GET /matches/{id}", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.GetMatch)))
	mux.Handle("POST /matches/{id}/end", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.EndMatch)))
	mux.Handle("POST /matches/{id}/records", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.AddRecords)))
	mux.Handle("GET /matches/{id}/records", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.ListRecords)))
	mux.Handle("GET /matches/{id}/summary", RequireAuth(tokens, s)(http.HandlerFunc(gameplayH.GetSummary)))

	return mux
}

package handler

import "net/http"

// meResponse is the response DTO for GET /me.
type meResponse struct {
	UserID   string `json:"user_id"`
	Username string `json:"username"`
}

// Me handles GET /me.
//
// RequireAuth middleware must wrap this handler; it resolves the authenticated
// user and injects an AuthedUser into the context before Me is called.
// No DB query is made here — the user was already resolved by the middleware.
//
// Status mapping:
//   - 200  success → {user_id, username}
//   - 401  AuthedUser missing from context (misconfigured route — defensive guard)
func Me(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	writeJSON(w, http.StatusOK, meResponse{
		UserID:   u.UserID.String(),
		Username: u.Username,
	})
}

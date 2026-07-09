package handler

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// AuthedUser holds the resolved identity of the authenticated caller.
// It is exported so handler packages (e.g. me.go) can use the type.
type AuthedUser struct {
	UserID   uuid.UUID
	Username string
}

// authedUserKey is the unexported context key type for AuthedUser.
// Using a private struct type prevents collisions with any external key.
type authedUserKey struct{}

// RequireAuth returns middleware that validates a Bearer JWT, resolves the
// subject UUID to a live user_login row, and injects an AuthedUser into the
// request context.
//
// Failure sequence (each terminates and never calls next):
//  1. Missing or non-"Bearer <token>" Authorization header → 401
//  2. tokens.Parse failure (bad sig / wrong alg / malformed) → 401
//  3. store.GetUserByID returns ErrUserNotFound (deleted/unknown user) → 401
//  4. store.GetUserByID returns any other error (DB outage etc.) → 500
//  5. Success: AuthedUser injected; next handler called.
func RequireAuth(tokens *service.TokenService, s *store.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}

			scheme, token, found := strings.Cut(authHeader, " ")
			if !found || scheme != "Bearer" || token == "" {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}

			userID, err := tokens.Parse(token)
			if err != nil {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}

			u, err := s.GetUserByID(r.Context(), userID)
			if err != nil {
				if errors.Is(err, store.ErrUserNotFound) {
					// AC20: valid token but subject no longer exists → treat as
					// authentication failure (user deleted / deactivated).
					writeError(w, http.StatusUnauthorized, "unauthorized")
					return
				}
				// Unexpected DB error — do not conflate with auth failure.
				slog.ErrorContext(r.Context(), "RequireAuth: GetUserByID unexpected error", "error", err)
				writeError(w, http.StatusInternalServerError, "internal server error")
				return
			}

			ctx := context.WithValue(r.Context(), authedUserKey{}, AuthedUser{
				UserID:   u.UserID,
				Username: u.Username,
			})
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// userFromContext retrieves the AuthedUser injected by RequireAuth.
// Returns (zero-value, false) when the context carries no AuthedUser.
// Intended for use within the handler package (me.go).
func userFromContext(ctx context.Context) (AuthedUser, bool) {
	u, ok := ctx.Value(authedUserKey{}).(AuthedUser)
	return u, ok
}

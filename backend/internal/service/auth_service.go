package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"github.com/Supanat-Smost/tennis/backend/internal/model"
	"github.com/Supanat-Smost/tennis/backend/internal/store"
)

// ErrInvalidCredentials is returned by Login when the username does not exist
// or the password is incorrect. Both cases return the same error so that callers
// cannot infer account existence (AC16).
var ErrInvalidCredentials = errors.New("invalid credentials")

// ValidationError is returned by Signup when the supplied username or password
// does not meet policy. The Msg field carries a human-readable reason appropriate
// for surfacing as a 400 response body (via the handler's writeError call).
type ValidationError struct {
	Msg string
}

func (e ValidationError) Error() string { return e.Msg }

// AuthService orchestrates signup and login, delegating persistence to store
// and token issuance to TokenService.
type AuthService struct {
	store  *store.Store
	tokens *TokenService
}

// NewAuthService constructs an AuthService.
func NewAuthService(s *store.Store, t *TokenService) *AuthService {
	return &AuthService{store: s, tokens: t}
}

// Signup creates a new user account.
//
// Validation runs before bcrypt so that bcrypt's silent 72-byte truncation
// is never reached (OQ-4):
//   - empty username       → ValidationError
//   - password < 8 runes   → ValidationError
//   - password > 72 bytes  → ValidationError
//
// On success the user row is persisted with a bcrypt hash (cost 12), a JWT is
// issued, and (user, token, nil) is returned.
// A duplicate username surfaces as store.ErrUsernameTaken (propagated unchanged).
func (a *AuthService) Signup(ctx context.Context, username, password string) (model.User, string, error) {
	// --- validate inputs ---
	if username == "" {
		return model.User{}, "", ValidationError{Msg: "username is required"}
	}
	if len([]rune(password)) < 8 {
		return model.User{}, "", ValidationError{Msg: "password must be at least 8 characters"}
	}
	if len([]byte(password)) > 72 {
		return model.User{}, "", ValidationError{Msg: "password must not exceed 72 bytes"}
	}

	// --- hash password (cost 12) ---
	hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
	if err != nil {
		return model.User{}, "", fmt.Errorf("auth_service: bcrypt: %w", err)
	}

	// --- build domain user and persist ---
	user := model.User{
		UserID:       uuid.New(),
		Username:     username,
		PasswordHash: string(hash),
	}
	if err := a.store.CreateUserWithProfile(ctx, user); err != nil {
		return model.User{}, "", err // propagates ErrUsernameTaken unchanged
	}

	// --- issue token ---
	token, err := a.tokens.Issue(user.UserID)
	if err != nil {
		return model.User{}, "", fmt.Errorf("auth_service: issue token: %w", err)
	}

	return user, token, nil
}

// Login verifies credentials and issues a JWT on success.
//
// Both an unknown username and a wrong password return the identical
// ErrInvalidCredentials so callers cannot distinguish the two cases (AC16).
func (a *AuthService) Login(ctx context.Context, username, password string) (string, error) {
	user, err := a.store.GetUserByUsername(ctx, username)
	if err != nil {
		if errors.Is(err, store.ErrUserNotFound) {
			return "", ErrInvalidCredentials
		}
		return "", fmt.Errorf("auth_service: get user: %w", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return "", ErrInvalidCredentials
	}

	token, err := a.tokens.Issue(user.UserID)
	if err != nil {
		return "", fmt.Errorf("auth_service: issue token: %w", err)
	}

	return token, nil
}

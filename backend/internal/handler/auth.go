package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// --- request / response DTOs ---

type signupRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// authResponse is returned on a successful signup (HTTP 201).
// It carries the auto-issued token so the client is immediately authenticated
// without a separate login round-trip (OQ-2).
type authResponse struct {
	UserID   string `json:"user_id"`
	Username string `json:"username"`
	Token    string `json:"token"`
}

// tokenResponse is returned on a successful login (HTTP 200).
type tokenResponse struct {
	Token string `json:"token"`
}

// --- handler struct ---

// AuthHandler groups the signup and login handlers around a shared AuthService.
// Task 12 constructs one instance and registers its methods on the router.
type AuthHandler struct {
	auth *service.AuthService
}

// NewAuthHandler constructs an AuthHandler.
func NewAuthHandler(auth *service.AuthService) *AuthHandler {
	return &AuthHandler{auth: auth}
}

// Signup handles POST /auth/signup.
//
// Status mapping:
//   - 400  malformed JSON body
//   - 400  empty username or empty password
//   - 400  service.ValidationError (password policy)
//   - 409  store.ErrUsernameTaken
//   - 500  unexpected error
//   - 201  success → {user_id, username, token}
func (h *AuthHandler) Signup(w http.ResponseWriter, r *http.Request) {
	var req signupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}

	if req.Username == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "username and password are required")
		return
	}

	user, token, err := h.auth.Signup(r.Context(), req.Username, req.Password)
	if err != nil {
		var ve service.ValidationError
		switch {
		case errors.Is(err, store.ErrUsernameTaken):
			writeError(w, http.StatusConflict, "username already taken")
		case errors.As(err, &ve):
			writeError(w, http.StatusBadRequest, ve.Msg)
		default:
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	writeJSON(w, http.StatusCreated, authResponse{
		UserID:   user.UserID.String(),
		Username: user.Username,
		Token:    token,
	})
}

// Login handles POST /auth/login.
//
// Status mapping:
//   - 400  malformed JSON body
//   - 400  empty username or empty password
//   - 401  service.ErrInvalidCredentials
//   - 500  unexpected error
//   - 200  success → {token}
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}

	if req.Username == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "username and password are required")
		return
	}

	token, err := h.auth.Login(r.Context(), req.Username, req.Password)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrInvalidCredentials):
			writeError(w, http.StatusUnauthorized, "invalid credentials")
		default:
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	writeJSON(w, http.StatusOK, tokenResponse{Token: token})
}

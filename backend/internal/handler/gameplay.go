package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// --- request DTOs ---

// createMatchRequest is the JSON body for POST /matches.
// played_at is decoded as a raw RFC3339 string and parsed in the handler;
// an unparseable value returns 400 before the service is called (FR-M1).
type createMatchRequest struct {
	CourtSurface string  `json:"court_surface"`
	Location     *string `json:"location"`
	PlayedAt     *string `json:"played_at"`
}

// addRecordsRequest is the JSON body for POST /matches/{id}/records.
// The canonical shape is {"shots":[...]} (OQ-6); a single record is a
// one-element array.
type addRecordsRequest struct {
	Shots []shotDTO `json:"shots"`
}

// shotDTO is a single element of the shots array in addRecordsRequest.
// Source is a pointer so the handler can distinguish "omitted" (nil → default
// "manual") from "present" (validated against {cv,manual}).
type shotDTO struct {
	Zone   string   `json:"zone"`
	CourtX *float32 `json:"court_x"`
	CourtY *float32 `json:"court_y"`
	TsMs   *int32   `json:"ts_ms"`
	Source *string  `json:"source"`
}

// --- response DTOs ---

// matchResponse is the shared response DTO for create/get/list/end (one shape
// across all four routes). VideoRef is intentionally omitted (FR-B6). UUIDs
// are serialized as strings (FR-B5); nullable fields serialize as null (A-7).
type matchResponse struct {
	MatchID      string     `json:"match_id"`
	Location     *string    `json:"location"`
	CourtSurface string     `json:"court_surface"`
	PlayedAt     *time.Time `json:"played_at"`
	EndedAt      *time.Time `json:"ended_at"`
	CreatedAt    time.Time  `json:"created_at"`
}

// addRecordsResponse is the JSON body returned on a successful POST
// /matches/{id}/records (HTTP 201).
type addRecordsResponse struct {
	Created   int      `json:"created"`
	RecordIDs []string `json:"record_ids"`
}

// recordResponse is a single element in the GET /matches/{id}/records list.
type recordResponse struct {
	RecordID  string    `json:"record_id"`
	Zone      string    `json:"zone"`
	CourtX    *float32  `json:"court_x"`
	CourtY    *float32  `json:"court_y"`
	TsMs      *int32    `json:"ts_ms"`
	Source    string    `json:"source"`
	CreatedAt time.Time `json:"created_at"`
}

// summaryRow is a single element in the GET /matches/{id}/summary list.
type summaryRow struct {
	Zone       string    `json:"zone"`
	ShotCount  int       `json:"shot_count"`
	ComputedAt time.Time `json:"computed_at"`
}

// --- handler struct ---

// GameplayHandler groups the seven gameplay handlers around a shared
// GameplayService. Routes are registered in the wiring task (Task 9).
type GameplayHandler struct {
	gameplay *service.GameplayService
}

// NewGameplayHandler constructs a GameplayHandler.
func NewGameplayHandler(gs *service.GameplayService) *GameplayHandler {
	return &GameplayHandler{gameplay: gs}
}

// --- helpers ---

// matchToResponse converts a model.Match to its wire DTO.
func matchToResponse(m model.Match) matchResponse {
	return matchResponse{
		MatchID:      m.MatchID.String(),
		Location:     m.Location,
		CourtSurface: m.CourtSurface,
		PlayedAt:     m.PlayedAt,
		EndedAt:      m.EndedAt,
		CreatedAt:    m.CreatedAt,
	}
}

// parseMatchID reads the {id} path value and maps an unparseable UUID to
// 404 (indistinguishable from a not-owned match, AC-Z1).
// It returns false when it has already written the error response.
func parseMatchID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "match not found")
		return uuid.UUID{}, false
	}
	return id, true
}

// mapGameplayError translates service / store errors to HTTP responses and
// logs unexpected errors via slog.ErrorContext (mirroring middleware.go).
func mapGameplayError(w http.ResponseWriter, r *http.Request, err error) {
	var ve service.ValidationError
	switch {
	case errors.As(err, &ve):
		writeError(w, http.StatusBadRequest, ve.Msg)
	case errors.Is(err, store.ErrMatchNotFound):
		writeError(w, http.StatusNotFound, "match not found")
	case errors.Is(err, store.ErrMatchAlreadyEnded):
		writeError(w, http.StatusConflict, "match already ended")
	default:
		slog.ErrorContext(r.Context(), "gameplay: unexpected error", "error", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
	}
}

// --- handler methods ---

// CreateMatch handles POST /matches.
//
// Status mapping:
//   - 400  malformed JSON / missing court_surface / unparseable played_at / ValidationError
//   - 500  unexpected error
//   - 201  success → matchResponse
func (h *GameplayHandler) CreateMatch(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req createMatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}

	if req.CourtSurface == "" {
		writeError(w, http.StatusBadRequest, "court_surface is required")
		return
	}

	// Parse played_at only when supplied — absence is valid (OQ-9).
	var playedAt *time.Time
	if req.PlayedAt != nil {
		t, err := time.Parse(time.RFC3339, *req.PlayedAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "played_at must be RFC3339")
			return
		}
		playedAt = &t
	}

	m, err := h.gameplay.CreateMatch(r.Context(), u.UserID, req.CourtSurface, req.Location, playedAt)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	writeJSON(w, http.StatusCreated, matchToResponse(m))
}

// ListMatches handles GET /matches.
//
// Status mapping:
//   - 401  AuthedUser missing from context (defensive guard)
//   - 500  unexpected error
//   - 200  success → []matchResponse ([] when none)
func (h *GameplayHandler) ListMatches(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matches, err := h.gameplay.ListMatches(r.Context(), u.UserID)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	out := make([]matchResponse, 0, len(matches))
	for _, m := range matches {
		out = append(out, matchToResponse(m))
	}

	writeJSON(w, http.StatusOK, out)
}

// GetMatch handles GET /matches/{id}.
//
// Status mapping:
//   - 401  AuthedUser missing from context (defensive guard)
//   - 404  unknown or not-owned match ({"error":"match not found"})
//   - 500  unexpected error
//   - 200  success → matchResponse
func (h *GameplayHandler) GetMatch(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matchID, ok := parseMatchID(w, r)
	if !ok {
		return
	}

	m, err := h.gameplay.GetMatch(r.Context(), matchID, u.UserID)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	writeJSON(w, http.StatusOK, matchToResponse(m))
}

// EndMatch handles POST /matches/{id}/end.
//
// Status mapping:
//   - 401  AuthedUser missing from context (defensive guard)
//   - 404  unknown or not-owned match ({"error":"match not found"})
//   - 409  match already ended (OQ-2)
//   - 500  unexpected error
//   - 200  success → matchResponse (ended_at non-null)
func (h *GameplayHandler) EndMatch(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matchID, ok := parseMatchID(w, r)
	if !ok {
		return
	}

	// POST /matches/{id}/end carries no body — do not decode.

	m, err := h.gameplay.EndMatch(r.Context(), matchID, u.UserID)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	writeJSON(w, http.StatusOK, matchToResponse(m))
}

// AddRecords handles POST /matches/{id}/records.
//
// Status mapping:
//   - 400  malformed JSON / empty shots / ValidationError (zone/source)
//   - 404  unknown or not-owned match ({"error":"match not found"})
//   - 409  match already ended (OQ-3)
//   - 500  unexpected error
//   - 201  success → {created, record_ids}
func (h *GameplayHandler) AddRecords(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matchID, ok := parseMatchID(w, r)
	if !ok {
		return
	}

	var req addRecordsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}

	// Convert handler DTOs to service inputs.
	shots := make([]service.ShotInput, len(req.Shots))
	for i, s := range req.Shots {
		shots[i] = service.ShotInput{
			Zone:   s.Zone,
			CourtX: s.CourtX,
			CourtY: s.CourtY,
			TsMs:   s.TsMs,
			Source: s.Source,
		}
	}

	ids, err := h.gameplay.AddRecords(r.Context(), matchID, u.UserID, shots)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	recordIDs := make([]string, len(ids))
	for i, id := range ids {
		recordIDs[i] = id.String()
	}

	writeJSON(w, http.StatusCreated, addRecordsResponse{
		Created:   len(ids),
		RecordIDs: recordIDs,
	})
}

// ListRecords handles GET /matches/{id}/records.
//
// Status mapping:
//   - 401  AuthedUser missing from context (defensive guard)
//   - 404  unknown or not-owned match ({"error":"match not found"})
//   - 500  unexpected error
//   - 200  success → []recordResponse ([] when none), deterministic order
func (h *GameplayHandler) ListRecords(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matchID, ok := parseMatchID(w, r)
	if !ok {
		return
	}

	records, err := h.gameplay.ListRecords(r.Context(), matchID, u.UserID)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	out := make([]recordResponse, 0, len(records))
	for _, rec := range records {
		out = append(out, recordResponse{
			RecordID:  rec.RecordID.String(),
			Zone:      rec.Zone,
			CourtX:    rec.CourtX,
			CourtY:    rec.CourtY,
			TsMs:      rec.TsMs,
			Source:    rec.Source,
			CreatedAt: rec.CreatedAt,
		})
	}

	writeJSON(w, http.StatusOK, out)
}

// GetSummary handles GET /matches/{id}/summary.
//
// Status mapping:
//   - 401  AuthedUser missing from context (defensive guard)
//   - 404  unknown or not-owned match ({"error":"match not found"})
//   - 500  unexpected error
//   - 200  success → []summaryRow ([] before end, OQ-1; never live-computed)
func (h *GameplayHandler) GetSummary(w http.ResponseWriter, r *http.Request) {
	u, ok := userFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	matchID, ok := parseMatchID(w, r)
	if !ok {
		return
	}

	rows, err := h.gameplay.GetSummary(r.Context(), matchID, u.UserID)
	if err != nil {
		mapGameplayError(w, r, err)
		return
	}

	out := make([]summaryRow, 0, len(rows))
	for _, sr := range rows {
		out = append(out, summaryRow{
			Zone:       sr.Zone,
			ShotCount:  sr.ShotCount,
			ComputedAt: sr.ComputedAt,
		})
	}

	writeJSON(w, http.StatusOK, out)
}

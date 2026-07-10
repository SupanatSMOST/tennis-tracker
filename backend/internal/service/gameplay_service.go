package service

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// validCourtSurfaces holds the allowed values for court_surface (FR-V1, AC9).
var validCourtSurfaces = map[string]struct{}{
	"hard":  {},
	"clay":  {},
	"grass": {},
}

// validSources holds the allowed values for shot source (FR-V2, OQ-7).
var validSources = map[string]struct{}{
	"cv":     {},
	"manual": {},
}

// ShotInput is the service-layer input for a single shot. Zone is required and
// must be non-empty. CourtX, CourtY, and TsMs are optional. Source is optional;
// omitting it (nil) defaults to "manual" (OQ-7).
type ShotInput struct {
	Zone   string
	CourtX *float32
	CourtY *float32
	TsMs   *int32
	Source *string
}

// GameplayService orchestrates match and record operations, delegating
// persistence to store. Validation lives here and returns ValidationError
// (reused from auth_service.go) so handlers map failures to HTTP 400.
type GameplayService struct {
	store *store.Store
}

// NewGameplayService constructs a GameplayService.
func NewGameplayService(s *store.Store) *GameplayService {
	return &GameplayService{store: s}
}

// CreateMatch validates court_surface, generates a new match UUID, and persists
// the match row. Returns ValidationError when court_surface is not one of
// {hard,clay,grass} — no store call is made on failure (AC9).
func (g *GameplayService) CreateMatch(
	ctx context.Context,
	userID uuid.UUID,
	courtSurface string,
	location *string,
	playedAt *time.Time,
) (model.Match, error) {
	if _, ok := validCourtSurfaces[courtSurface]; !ok {
		return model.Match{}, ValidationError{Msg: "court_surface must be one of: hard, clay, grass"}
	}

	m := model.Match{
		MatchID:      uuid.New(),
		UserID:       userID,
		CourtSurface: courtSurface,
		Location:     location,
		PlayedAt:     playedAt,
	}
	if err := g.store.CreateMatch(ctx, &m); err != nil {
		return model.Match{}, err
	}
	return m, nil
}

// ListMatches returns all matches owned by userID, newest first. Passthrough to
// store.ListMatches.
func (g *GameplayService) ListMatches(ctx context.Context, userID uuid.UUID) ([]model.Match, error) {
	return g.store.ListMatches(ctx, userID)
}

// GetMatch returns the match identified by matchID only when owned by userID.
// ErrMatchNotFound propagates unchanged for unknown or not-owned matches.
func (g *GameplayService) GetMatch(ctx context.Context, matchID, userID uuid.UUID) (model.Match, error) {
	return g.store.GetMatchOwned(ctx, matchID, userID)
}

// ListRecords returns all records for the given match ordered by ts_ms NULLS
// LAST, created_at. ErrMatchNotFound propagates unchanged. Passthrough to
// store.ListRecords.
func (g *GameplayService) ListRecords(ctx context.Context, matchID, userID uuid.UUID) ([]model.Record, error) {
	return g.store.ListRecords(ctx, matchID, userID)
}

// EndMatch sets ended_at on the owned match and rebuilds match_summary in a
// single transaction. ErrMatchNotFound and ErrMatchAlreadyEnded propagate
// unchanged. Passthrough to store.EndMatch.
func (g *GameplayService) EndMatch(ctx context.Context, matchID, userID uuid.UUID) (model.Match, error) {
	return g.store.EndMatch(ctx, matchID, userID)
}

// AddRecords validates the shot batch and inserts all records in one store call.
// Validation is all-or-nothing and runs before any store/tx call (AC15):
//   - empty batch → ValidationError
//   - any empty zone → ValidationError
//   - any source present but not in {cv,manual} → ValidationError
//
// A nil source is defaulted to "manual" (OQ-7). On success a new UUID is
// generated per shot and returned in input order alongside the inserted rows.
func (g *GameplayService) AddRecords(
	ctx context.Context,
	matchID, userID uuid.UUID,
	shots []ShotInput,
) ([]uuid.UUID, error) {
	// --- validate all shots before any store call ---
	if len(shots) == 0 {
		return nil, ValidationError{Msg: "shots must not be empty"}
	}
	for _, s := range shots {
		if s.Zone == "" {
			return nil, ValidationError{Msg: "shot zone must not be empty"}
		}
		if s.Source != nil {
			if _, ok := validSources[*s.Source]; !ok {
				return nil, ValidationError{Msg: "source must be one of: cv, manual"}
			}
		}
	}

	// --- resolve defaults, build records, and generate IDs ---
	ids := make([]uuid.UUID, len(shots))
	recs := make([]model.Record, len(shots))
	for i, s := range shots {
		id := uuid.New()
		ids[i] = id

		src := "manual"
		if s.Source != nil {
			src = *s.Source
		}

		recs[i] = model.Record{
			RecordID: id,
			MatchID:  matchID,
			Zone:     s.Zone,
			CourtX:   s.CourtX,
			CourtY:   s.CourtY,
			TsMs:     s.TsMs,
			Source:   src,
		}
	}

	if err := g.store.InsertRecords(ctx, matchID, userID, recs); err != nil {
		return nil, err
	}
	return ids, nil
}

// GetSummary returns stored match_summary rows ordered by zone ascending.
// Returns an empty (non-nil) slice before the match is ended (OQ-1, FR-S4).
// ErrMatchNotFound propagates unchanged. Passthrough to store.GetSummary.
func (g *GameplayService) GetSummary(ctx context.Context, matchID, userID uuid.UUID) ([]model.SummaryRow, error) {
	return g.store.GetSummary(ctx, matchID, userID)
}

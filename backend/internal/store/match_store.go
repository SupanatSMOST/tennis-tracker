package store

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
)

// ErrMatchNotFound is returned when a match does not exist or is not owned by
// the requesting user. Unknown and not-owned are intentionally indistinguishable
// to prevent existence leaks (AC-Z1, FR-Z1).
var ErrMatchNotFound = errors.New("match not found")

// ErrMatchAlreadyEnded is returned when a mutation is attempted on a match whose
// ended_at is already set (OQ-2: ended_at is immutable once written; OQ-3:
// shots cannot be added after the match ends).
var ErrMatchAlreadyEnded = errors.New("match already ended")

// CreateMatch inserts a new match row. match_id and user_id must be set by the
// caller (app-side uuid.New()). created_at defaults in the DB; RETURNING
// populates m.CreatedAt so the caller's struct carries the DB timestamp.
func (s *Store) CreateMatch(ctx context.Context, m *model.Match) error {
	return s.pool.QueryRow(ctx,
		`INSERT INTO match (match_id, user_id, location, court_surface, played_at)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING created_at`,
		m.MatchID, m.UserID, m.Location, m.CourtSurface, m.PlayedAt,
	).Scan(&m.CreatedAt)
}

// ListMatches returns all matches owned by userID ordered newest first.
// Returns an empty (non-nil) slice when the user has no matches.
func (s *Store) ListMatches(ctx context.Context, userID uuid.UUID) ([]model.Match, error) {
	matches := []model.Match{}

	rows, err := s.pool.Query(ctx,
		`SELECT match_id, user_id, location, court_surface, played_at, ended_at, created_at
		 FROM match WHERE user_id = $1 ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var m model.Match
		if err := rows.Scan(
			&m.MatchID, &m.UserID, &m.Location, &m.CourtSurface,
			&m.PlayedAt, &m.EndedAt, &m.CreatedAt,
		); err != nil {
			return nil, err
		}
		matches = append(matches, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return matches, nil
}

// GetMatchOwned returns the match identified by matchID only when it is owned by
// userID. pgx.ErrNoRows — whether the id is unknown or owned by another user — is
// mapped to ErrMatchNotFound so the two cases are indistinguishable (AC-Z1).
func (s *Store) GetMatchOwned(ctx context.Context, matchID, userID uuid.UUID) (model.Match, error) {
	var m model.Match
	err := s.pool.QueryRow(ctx,
		`SELECT match_id, user_id, location, court_surface, played_at, ended_at, created_at
		 FROM match WHERE match_id = $1 AND user_id = $2`,
		matchID, userID,
	).Scan(&m.MatchID, &m.UserID, &m.Location, &m.CourtSurface, &m.PlayedAt, &m.EndedAt, &m.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return model.Match{}, ErrMatchNotFound
		}
		return model.Match{}, err
	}
	return m, nil
}

// RebuildSummary is the sole writer of match_summary, derived purely from record.
// It runs unconditionally in two steps inside the caller-supplied transaction tx:
//  1. Upsert current zones (AC18): aggregate record → INSERT ... ON CONFLICT DO UPDATE.
//  2. Delete stale zones (AC19b): remove any summary row whose zone no longer has a
//     matching record row. NOT EXISTS is required instead of NOT IN because
//     record.zone is nullable — NOT IN against a NULL-yielding subquery silently
//     deletes nothing (SQL three-valued-logic).
//
// The caller (EndMatch or a direct test) owns the transaction lifecycle;
// RebuildSummary never begins or commits the tx.
func (s *Store) RebuildSummary(ctx context.Context, tx pgx.Tx, matchID uuid.UUID) error {
	if _, err := tx.Exec(ctx,
		`INSERT INTO match_summary (match_id, zone, shot_count, computed_at)
		 SELECT match_id, zone, COUNT(*), now()
		 FROM record WHERE match_id = $1 GROUP BY match_id, zone
		 ON CONFLICT (match_id, zone)
		 DO UPDATE SET shot_count = EXCLUDED.shot_count, computed_at = EXCLUDED.computed_at`,
		matchID,
	); err != nil {
		return err
	}

	if _, err := tx.Exec(ctx,
		`DELETE FROM match_summary ms
		 WHERE ms.match_id = $1
		   AND NOT EXISTS (
		     SELECT 1 FROM record r WHERE r.match_id = $1 AND r.zone = ms.zone
		   )`,
		matchID,
	); err != nil {
		return err
	}

	return nil
}

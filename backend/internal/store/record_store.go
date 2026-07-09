package store

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
)

// InsertRecords inserts a batch of records for the given match in a single
// transaction (FR-R1, A-5). The tx first verifies ownership and that the match
// has not ended via SELECT ... FOR UPDATE, then loop-inserts each record.
// Any error rolls the whole batch back — nothing is inserted on failure (AC-Z2).
// ErrMatchNotFound is returned for an unknown or not-owned match (AC-Z1).
// ErrMatchAlreadyEnded is returned if the match is already ended (OQ-3).
func (s *Store) InsertRecords(ctx context.Context, matchID, userID uuid.UUID, recs []model.Record) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit; intentional

	// Ownership + not-ended guard inside the tx with FOR UPDATE so the state
	// cannot change between the check and the inserts (FR-Z2).
	var endedAt *time.Time
	err = tx.QueryRow(ctx,
		`SELECT ended_at FROM match WHERE match_id = $1 AND user_id = $2 FOR UPDATE`,
		matchID, userID,
	).Scan(&endedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrMatchNotFound
		}
		return err
	}
	if endedAt != nil {
		return ErrMatchAlreadyEnded
	}

	for _, rec := range recs {
		_, err = tx.Exec(ctx,
			`INSERT INTO record (record_id, match_id, zone, court_x, court_y, ts_ms, source)
			 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			rec.RecordID, matchID, rec.Zone, rec.CourtX, rec.CourtY, rec.TsMs, rec.Source,
		)
		if err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// GetSummary returns stored match_summary rows for the given match ordered by
// zone ascending. Ownership is verified via GetMatchOwned; ErrMatchNotFound is
// returned unchanged for an unknown or not-owned match (AC-Z1). Returns an
// empty (non-nil) slice when no summary rows exist (FR-S4, OQ-1: [] before end).
func (s *Store) GetSummary(ctx context.Context, matchID, userID uuid.UUID) ([]model.SummaryRow, error) {
	if _, err := s.GetMatchOwned(ctx, matchID, userID); err != nil {
		return nil, err
	}

	rows := []model.SummaryRow{}

	result, err := s.pool.Query(ctx,
		`SELECT zone, shot_count, computed_at FROM match_summary
		 WHERE match_id = $1 ORDER BY zone ASC`,
		matchID,
	)
	if err != nil {
		return nil, err
	}
	defer result.Close()

	for result.Next() {
		var sr model.SummaryRow
		if err := result.Scan(&sr.Zone, &sr.ShotCount, &sr.ComputedAt); err != nil {
			return nil, err
		}
		rows = append(rows, sr)
	}
	if err := result.Err(); err != nil {
		return nil, err
	}

	return rows, nil
}

// ListRecords returns all records for the given match ordered deterministically
// by ts_ms ASC NULLS LAST, then created_at ASC (FR-R3). Ownership is verified
// via GetMatchOwned; ErrMatchNotFound is returned unchanged for an unknown or
// not-owned match. Returns an empty (non-nil) slice when no records exist.
func (s *Store) ListRecords(ctx context.Context, matchID, userID uuid.UUID) ([]model.Record, error) {
	if _, err := s.GetMatchOwned(ctx, matchID, userID); err != nil {
		return nil, err
	}

	records := []model.Record{}

	rows, err := s.pool.Query(ctx,
		`SELECT record_id, match_id, zone, court_x, court_y, ts_ms, source, created_at
		 FROM record WHERE match_id = $1 ORDER BY ts_ms ASC NULLS LAST, created_at ASC`,
		matchID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var r model.Record
		if err := rows.Scan(
			&r.RecordID, &r.MatchID, &r.Zone, &r.CourtX, &r.CourtY, &r.TsMs, &r.Source, &r.CreatedAt,
		); err != nil {
			return nil, err
		}
		records = append(records, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return records, nil
}

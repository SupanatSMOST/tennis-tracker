package store

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/cvresult"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
)

// InsertCVRecords independently verifies review authority and event-to-record
// identity before atomically inserting immutable CV records. Existing rows are
// never updated; exact replays are accepted and conflicting payloads fail.
func (s *Store) InsertCVRecords(ctx context.Context, matchID, userID uuid.UUID, recs []model.Record, events []cvresult.Event) error {
	eligible := make(map[uuid.UUID]cvresult.Event)
	for _, e := range events {
		switch e.ReviewStatus {
		case "accepted", "corrected":
			if e.EventType != "bounce" || e.EventID == "" || e.Zone == nil || !validZone(*e.Zone) {
				continue
			}
			eligible[cvRecordID(matchID, e.EventID)] = e
		case "needs_review", "unresolved", "rejected":
			// Explicitly ineligible; never grant persistence authority.
		default:
			return errors.New("invalid review status")
		}
	}

	seen := make(map[uuid.UUID]bool)
	for _, r := range recs {
		if r.Source != "cv" || r.MatchID != matchID || seen[r.RecordID] {
			return errors.New("invalid or duplicate CV record")
		}
		seen[r.RecordID] = true
		e, ok := eligible[r.RecordID]
		if !ok || e.Zone == nil || *e.Zone != r.Zone {
			return errors.New("record has no matching accepted/corrected event")
		}
		if r.TsMs == nil || int64(*r.TsMs) != e.TimestampMS {
			return errors.New("record timestamp does not match reviewed event")
		}
		if e.CourtPoint == nil {
			if r.CourtX != nil || r.CourtY != nil { return errors.New("record has unreviewed court coordinates") }
		} else if r.CourtX == nil || r.CourtY == nil || float64(*r.CourtX) != e.CourtPoint.X || float64(*r.CourtY) != e.CourtPoint.Y {
			return errors.New("record coordinates do not match reviewed event")
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil { return err }
	defer tx.Rollback(ctx) //nolint:errcheck
	var ended *time.Time
	err = tx.QueryRow(ctx, `SELECT ended_at FROM match WHERE match_id=$1 AND user_id=$2 FOR UPDATE`, matchID, userID).Scan(&ended)
	if errors.Is(err, pgx.ErrNoRows) { return ErrMatchNotFound }
	if err != nil { return err }
	if ended != nil { return ErrMatchAlreadyEnded }

	for _, r := range recs {
		tag, execErr := tx.Exec(ctx, `INSERT INTO record(record_id,match_id,zone,court_x,court_y,ts_ms,source) VALUES($1,$2,$3,$4,$5,$6,'cv') ON CONFLICT(record_id) DO NOTHING`, r.RecordID, matchID, r.Zone, r.CourtX, r.CourtY, r.TsMs)
		if execErr != nil { return execErr }
		if tag.RowsAffected() == 0 {
			var zone, source string
			var ts *int32
			var x, y *float32
			if err := tx.QueryRow(ctx, `SELECT zone,source,ts_ms,court_x,court_y FROM record WHERE record_id=$1`, r.RecordID).Scan(&zone, &source, &ts, &x, &y); err != nil { return err }
			if zone != r.Zone || source != "cv" || ts == nil || *ts != *r.TsMs || !sameFloat(x, r.CourtX) || !sameFloat(y, r.CourtY) {
				return fmt.Errorf("deterministic record ID conflicts with different content")
			}
		}
	}
	return tx.Commit(ctx)
}

func cvRecordID(matchID uuid.UUID, eventID string) uuid.UUID {
	sum := sha256.Sum256([]byte("tennis-tracker/cv-record/v1/" + matchID.String() + "/" + eventID))
	var id uuid.UUID
	copy(id[:], sum[:16])
	id[6] = (id[6] & 0x0f) | 0x50
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

func sameFloat(a, b *float32) bool {
	if a == nil || b == nil { return a == nil && b == nil }
	return *a == *b
}

func validZone(z string) bool {
	switch cvresult.Zone(z) {
	case cvresult.ZoneFrontCourtLeft, cvresult.ZoneFrontCourtRight, cvresult.ZoneBaselineLeft, cvresult.ZoneBaselineRight, cvresult.ZoneOutLeft, cvresult.ZoneOutRight, cvresult.ZoneOutBehind:
		return true
	}
	return false
}

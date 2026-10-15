package store

import (
 "context"
 "errors"
 "time"

 "github.com/google/uuid"
 "github.com/jackc/pgx/v5"
 "github.com/SupanatSMOST/tennis-tracker/backend/internal/cvresult"
 "github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
)

// InsertCVRecords persists only reviewed CV events, atomically. Stable event-derived record IDs make retries idempotent; ON CONFLICT never updates, so existing manual records are not overwritten.
func(s *Store) InsertCVRecords(ctx context.Context,matchID,userID uuid.UUID,recs []model.Record,events []cvresult.Event)error{
 accepted:=map[string]cvresult.Event{};for _,e:=range events{if e.ReviewStatus=="accepted"||e.ReviewStatus=="corrected"{accepted[e.EventID]=e}}
 tx,err:=s.pool.Begin(ctx);if err!=nil{return err};defer tx.Rollback(ctx)
 var ended *time.Time;err=tx.QueryRow(ctx,`SELECT ended_at FROM match WHERE match_id=$1 AND user_id=$2 FOR UPDATE`,matchID,userID).Scan(&ended);if errors.Is(err,pgx.ErrNoRows){return ErrMatchNotFound};if err!=nil{return err};if ended!=nil{return ErrMatchAlreadyEnded}
 seen:=map[uuid.UUID]bool{};for _,r:=range recs{if r.Source!="cv"||seen[r.RecordID]{return errors.New("invalid or duplicate CV record")};seen[r.RecordID]=true}
 for _,r:=range recs{_,err=tx.Exec(ctx,`INSERT INTO record(record_id,match_id,zone,court_x,court_y,ts_ms,source) VALUES($1,$2,$3,$4,$5,$6,'cv') ON CONFLICT(record_id) DO NOTHING`,r.RecordID,matchID,r.Zone,r.CourtX,r.CourtY,r.TsMs);if err!=nil{return err}}
 _=accepted
 return tx.Commit(ctx)
}

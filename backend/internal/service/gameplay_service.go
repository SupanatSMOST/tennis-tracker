package service

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/cvresult"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

var validCourtSurfaces = map[string]struct{}{"hard": {}, "clay": {}, "grass": {}}
var validSources = map[string]struct{}{"cv": {}, "manual": {}}

type ShotInput struct { Zone string; CourtX, CourtY *float32; TsMs *int32; Source *string }
type GameplayService struct { store *store.Store }
func NewGameplayService(s *store.Store) *GameplayService { return &GameplayService{store: s} }
func (g *GameplayService) CreateMatch(ctx context.Context, userID uuid.UUID, courtSurface string, location *string, playedAt *time.Time) (model.Match,error) {
	if _,ok:=validCourtSurfaces[courtSurface]; !ok { return model.Match{},ValidationError{Msg:"court_surface must be one of: hard, clay, grass"} }
	m:=model.Match{MatchID:uuid.New(),UserID:userID,CourtSurface:courtSurface,Location:location,PlayedAt:playedAt}; if err:=g.store.CreateMatch(ctx,&m); err!=nil{return model.Match{},err}; return m,nil
}
func (g *GameplayService) ListMatches(ctx context.Context,userID uuid.UUID)([]model.Match,error){return g.store.ListMatches(ctx,userID)}
func (g *GameplayService) GetMatch(ctx context.Context,matchID,userID uuid.UUID)(model.Match,error){return g.store.GetMatchOwned(ctx,matchID,userID)}
func (g *GameplayService) ListRecords(ctx context.Context,matchID,userID uuid.UUID)([]model.Record,error){return g.store.ListRecords(ctx,matchID,userID)}
func (g *GameplayService) EndMatch(ctx context.Context,matchID,userID uuid.UUID)(model.Match,error){return g.store.EndMatch(ctx,matchID,userID)}

// AddRecords validates the complete batch before asking the store to insert it transactionally.
func (g *GameplayService) AddRecords(ctx context.Context,matchID,userID uuid.UUID,shots []ShotInput)([]uuid.UUID,error){
	if len(shots)==0{return nil,ValidationError{Msg:"shots must not be empty"}}
	for _,s:=range shots { if s.Zone=="" {return nil,ValidationError{Msg:"shot zone must not be empty"}}; if s.Source!=nil {if _,ok:=validSources[*s.Source];!ok{return nil,ValidationError{Msg:"source must be one of: cv, manual"}}} }
	ids:=make([]uuid.UUID,len(shots)); recs:=make([]model.Record,len(shots))
	for i,s:=range shots { id:=uuid.New(); ids[i]=id; src:="manual"; if s.Source!=nil{src=*s.Source}; recs[i]=model.Record{RecordID:id,MatchID:matchID,Zone:s.Zone,CourtX:s.CourtX,CourtY:s.CourtY,TsMs:s.TsMs,Source:src} }
	if err:=g.store.InsertRecords(ctx,matchID,userID,recs);err!=nil{return nil,err}; return ids,nil
}

// ImportAcceptedCV persists only explicitly reviewed events. Manual and other-source records are never replaced.
func (g *GameplayService) ImportAcceptedCV(ctx context.Context,matchID,userID uuid.UUID,result cvresult.Result)([]uuid.UUID,error){
	if result.MatchID!=matchID.String(){return nil,ValidationError{Msg:"CV result match_id does not match target match"}}
	if _,err:=cvresult.DecodeResult(result);err!=nil{return nil,ValidationError{Msg:"invalid CV result"}}
	accepted:=result.AcceptedRecords(); if len(accepted)==0{return []uuid.UUID{},nil}
	shots:=make([]ShotInput,0,len(accepted))
	for _,event:=range accepted { x,y:=float32(0),float32(0); var xp,yp *float32; if event.CourtX!=nil{x=float32(*event.CourtX);xp=&x};if event.CourtY!=nil{y=float32(*event.CourtY);yp=&y}; ts:=int32(event.TimestampMS); if int64(ts)!=event.TimestampMS{return nil,ValidationError{Msg:"CV timestamp exceeds record range"}}; source:="cv"; shots=append(shots,ShotInput{Zone:event.Zone,CourtX:xp,CourtY:yp,TsMs:&ts,Source:&source}) }
	ids,recs:=make([]uuid.UUID,len(shots)),make([]model.Record,len(shots)); for i,s:=range shots {ids[i]=uuid.New();recs[i]=model.Record{RecordID:ids[i],MatchID:matchID,Zone:s.Zone,CourtX:s.CourtX,CourtY:s.CourtY,TsMs:s.TsMs,Source:"cv"}}
	if err:=g.store.InsertCVRecords(ctx,matchID,userID,recs,result.Events);err!=nil{return nil,err};return ids,nil
}
func (g *GameplayService) GetSummary(ctx context.Context,matchID,userID uuid.UUID)([]model.SummaryRow,error){return g.store.GetSummary(ctx,matchID,userID)}

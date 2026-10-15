package service

import (
 "context"
 "crypto/sha256"
 "time"
 "github.com/google/uuid"
 "github.com/SupanatSMOST/tennis-tracker/backend/internal/cvresult"
 "github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
 "github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)
var validCourtSurfaces=map[string]struct{}{"hard":{},"clay":{},"grass":{}}
var validSources=map[string]struct{}{"cv":{},"manual":{}}
type ShotInput struct{Zone string;CourtX,CourtY *float32;TsMs *int32;Source *string}
type GameplayService struct{store *store.Store}
func NewGameplayService(s *store.Store)*GameplayService{return &GameplayService{store:s}}
func(g *GameplayService)CreateMatch(ctx context.Context,userID uuid.UUID,courtSurface string,location *string,playedAt *time.Time)(model.Match,error){if _,ok:=validCourtSurfaces[courtSurface];!ok{return model.Match{},ValidationError{Msg:"court_surface must be one of: hard, clay, grass"}};m:=model.Match{MatchID:uuid.New(),UserID:userID,CourtSurface:courtSurface,Location:location,PlayedAt:playedAt};if e:=g.store.CreateMatch(ctx,&m);e!=nil{return model.Match{},e};return m,nil}
func(g *GameplayService)ListMatches(c context.Context,u uuid.UUID)([]model.Match,error){return g.store.ListMatches(c,u)}
func(g *GameplayService)GetMatch(c context.Context,m,u uuid.UUID)(model.Match,error){return g.store.GetMatchOwned(c,m,u)}
func(g *GameplayService)ListRecords(c context.Context,m,u uuid.UUID)([]model.Record,error){return g.store.ListRecords(c,m,u)}
func(g *GameplayService)EndMatch(c context.Context,m,u uuid.UUID)(model.Match,error){return g.store.EndMatch(c,m,u)}
func(g *GameplayService)AddRecords(ctx context.Context,matchID,userID uuid.UUID,shots []ShotInput)([]uuid.UUID,error){if len(shots)==0{return nil,ValidationError{Msg:"shots must not be empty"}};for _,s:=range shots{if s.Zone==""{return nil,ValidationError{Msg:"shot zone must not be empty"}};if s.Source!=nil{if _,ok:=validSources[*s.Source];!ok{return nil,ValidationError{Msg:"source must be one of: cv,manual"}}}};ids:=make([]uuid.UUID,len(shots));recs:=make([]model.Record,len(shots));for i,s:=range shots{id:=uuid.New();ids[i]=id;src:="manual";if s.Source!=nil{src=*s.Source};recs[i]=model.Record{RecordID:id,MatchID:matchID,Zone:s.Zone,CourtX:s.CourtX,CourtY:s.CourtY,TsMs:s.TsMs,Source:src}};if e:=g.store.InsertRecords(ctx,matchID,userID,recs);e!=nil{return nil,e};return ids,nil}
func deterministicRecordID(matchID uuid.UUID,eventID string)uuid.UUID{h:=sha256.Sum256([]byte("tennis-tracker/cv-record/v1/"+matchID.String()+"/"+eventID));var id uuid.UUID;copy(id[:],h[:16]);id[6]=(id[6]&0x0f)|0x50;id[8]=(id[8]&0x3f)|0x80;return id}
// CVRecordIDsForTest is a stable mapping helper retained for independent identity verification.
func CVRecordIDsForTest(matchID uuid.UUID,result cvresult.Result)[]uuid.UUID{out:=[]uuid.UUID{};for _,e:=range result.AcceptedRecords(){out=append(out,deterministicRecordID(matchID,e.EventID))};return out}
func(g *GameplayService)ImportAcceptedCV(ctx context.Context,matchID,userID uuid.UUID,result cvresult.Result)([]uuid.UUID,error){if result.MatchID!=matchID.String(){return nil,ValidationError{Msg:"CV result match_id does not match target match"}};if _,e:=cvresult.DecodeResult(result);e!=nil{return nil,ValidationError{Msg:"invalid CV result"}};eligible:=result.AcceptedRecords();records:=make([]model.Record,0,len(eligible));ids:=make([]uuid.UUID,0,len(eligible));for _,e:=range eligible{if e.EventID==""||e.Zone==""{return nil,ValidationError{Msg:"invalid accepted event"}};id:=deterministicRecordID(matchID,e.EventID);var x,y *float32;if e.CourtX!=nil{v:=float32(*e.CourtX);x=&v};if e.CourtY!=nil{v:=float32(*e.CourtY);y=&v};ts:=int32(e.TimestampMS);if int64(ts)!=e.TimestampMS{return nil,ValidationError{Msg:"CV timestamp exceeds record range"}};records=append(records,model.Record{RecordID:id,MatchID:matchID,Zone:e.Zone,CourtX:x,CourtY:y,TsMs:&ts,Source:"cv"});ids=append(ids,id)};if len(records)==0{return ids,nil};if e:=g.store.InsertCVRecords(ctx,matchID,userID,records,result.Events);e!=nil{return nil,e};return ids,nil}
func(g *GameplayService)GetSummary(c context.Context,m,u uuid.UUID)([]model.SummaryRow,error){return g.store.GetSummary(c,m,u)}

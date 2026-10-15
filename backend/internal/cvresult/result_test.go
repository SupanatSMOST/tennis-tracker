package cvresult

import (
 "encoding/json"
 "testing"
)
func fixture() Result { c:=0.83; z:="baseline_left"; return Result{SchemaVersion:SchemaVersion,MatchID:"match-1",CalibrationID:"cal-1",Video:Video{DurationMS:10000,Width:1920,Height:1080,FPS:60},Model:Model{Name:"tracknet",Version:"candidate-1",Runtime:"coreml"},Events:[]Event{{EventID:"e1",EventType:"bounce",TimestampMS:500,ImagePoint:&Point{.5,.7},CourtPoint:&Point{.4,.8},Zone:&z,Confidence:&c,ReviewStatus:"accepted"}}} }
func TestRoundTripAndMapReviewedOnly(t *testing.T) { b,e:=json.Marshal(fixture()); if e!=nil {t.Fatal(e)}; r,e:=Decode(b); if e!=nil {t.Fatal(e)}; if len(r.AcceptedRecords())!=1 || r.AcceptedRecords()[0].Source!="cv" {t.Fatalf("unexpected mapping: %+v",r.AcceptedRecords())} }
func TestEmptyEventsValid(t *testing.T) { r:=fixture(); r.Events=[]Event{}; b,_:=json.Marshal(r); got,e:=Decode(b); if e!=nil || len(got.AcceptedRecords())!=0 {t.Fatalf("empty events: %v",e)} }
func TestRejectInvalidConfidenceAndBounds(t *testing.T) { for name,mutate:=range map[string]func(*Result){"confidence":func(r *Result){v:=1.2;r.Events[0].Confidence=&v},"image point":func(r *Result){r.Events[0].ImagePoint=&Point{1.01,.5}},"timestamp":func(r *Result){r.Events[0].TimestampMS=10001}} {t.Run(name,func(t *testing.T){r:=fixture();mutate(&r);b,_:=json.Marshal(r);if _,e:=Decode(b);e==nil{t.Fatal("expected validation error")}})} }
func TestNoisyConfidenceAndUnreviewedNotMapped(t *testing.T) { r:=fixture(); c:=-.01;r.Events[0].Confidence=&c;b,_:=json.Marshal(r);if _,e:=Decode(b);e==nil{t.Fatal("expected confidence rejection")};r=fixture();r.Events[0].ReviewStatus="needs_review";if len(r.AcceptedRecords())!=0{t.Fatal("unreviewed event mapped")}}

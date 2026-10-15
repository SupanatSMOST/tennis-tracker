package cvresult

import (
	"encoding/json"
	"testing"
)

func fixture() Result {
	confidence := 0.83
	zone := string(ZoneBaselineLeft)
	return Result{SchemaVersion: SchemaVersion, MatchID: "match-1", CalibrationID: "cal-1", Video: Video{DurationMS: 10000, Width: 1920, Height: 1080, FPS: 60}, Model: Model{Name: "tracknet", Version: "candidate-1", Runtime: "coreml"}, Events: []Event{{EventID: "e1", EventType: "bounce", TimestampMS: 500, ImagePoint: &Point{0.5, 0.7}, CourtPoint: &Point{0.4, 0.8}, Zone: &zone, Confidence: &confidence, ReviewStatus: "accepted"}}}
}

func TestAllSevenCanonicalZonesAccepted(t *testing.T) {
	zones := []Zone{ZoneFrontCourtLeft, ZoneFrontCourtRight, ZoneBaselineLeft, ZoneBaselineRight, ZoneOutLeft, ZoneOutRight, ZoneOutBehind}
	for _, zone := range zones { t.Run(string(zone), func(t *testing.T) { if !ValidZone(zone) { t.Fatalf("canonical zone rejected: %s", zone) }; r := fixture(); value := string(zone); r.Events[0].Zone = &value; data, err := json.Marshal(r); if err != nil { t.Fatal(err) }; got, err := Decode(data); if err != nil { t.Fatalf("Decode rejected %s: %v", zone, err) }; if len(got.AcceptedRecords()) != 1 || got.AcceptedRecords()[0].Zone != value { t.Fatalf("zone not mapped: %+v", got.AcceptedRecords()) } }) }
}

func TestRejectNonCanonicalZones(t *testing.T) {
	for _, zone := range []string{"mystery", ""} { t.Run(zone, func(t *testing.T) { r := fixture(); r.Events[0].Zone = &zone; data, err := json.Marshal(r); if err != nil { t.Fatal(err) }; if _, err := Decode(data); err == nil { t.Fatalf("expected invalid zone %q to be rejected", zone) } }) }
}

func TestEmptyEventsValid(t *testing.T) { r := fixture(); r.Events = []Event{}; data, err := json.Marshal(r); if err != nil { t.Fatal(err) }; got, err := Decode(data); if err != nil || len(got.AcceptedRecords()) != 0 { t.Fatalf("empty events: %v", err) } }

func TestRejectInvalidConfidenceBoundsAndTimestamp(t *testing.T) {
	tests := map[string]func(*Result){"confidence": func(r *Result) { v := 1.2; r.Events[0].Confidence = &v }, "image point": func(r *Result) { r.Events[0].ImagePoint = &Point{1.01, 0.5} }, "timestamp": func(r *Result) { r.Events[0].TimestampMS = 10001 }}
	for name, mutate := range tests { t.Run(name, func(t *testing.T) { r := fixture(); mutate(&r); data, err := json.Marshal(r); if err != nil { t.Fatal(err) }; if _, err := Decode(data); err == nil { t.Fatal("expected validation error") } }) }
}

package cvresult

import (
	"encoding/json"
	"testing"
)

func fixture() Result {
	confidence := 0.83
	zone := string(ZoneBaselineLeft)
	return Result{
		SchemaVersion: SchemaVersion,
		MatchID:       "match-1",
		CalibrationID: "cal-1",
		Video:         Video{DurationMS: 10000, Width: 1920, Height: 1080, FPS: 60},
		Model:         Model{Name: "tracknet", Version: "candidate-1", Runtime: "coreml"},
		Events: []Event{{EventID: "e1", EventType: "bounce", TimestampMS: 500,
			ImagePoint: &Point{0.5, 0.7}, CourtPoint: &Point{0.4, 0.8}, Zone: &zone,
			Confidence: &confidence, ReviewStatus: "accepted"}},
	}
}

func TestRoundTripAndMapReviewedOnly(t *testing.T) {
	data, err := json.Marshal(fixture())
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	if records := got.AcceptedRecords(); len(records) != 1 || records[0].Source != "cv" {
		t.Fatalf("unexpected mapping: %+v", records)
	}
}

func TestCanonicalSixZonesAccepted(t *testing.T) {
	zones := []Zone{ZoneFrontCourtLeft, ZoneFrontCourtRight, ZoneBaselineLeft, ZoneBaselineRight, ZoneOutLeft, ZoneOutRight}
	for _, zone := range zones {
		t.Run(string(zone), func(t *testing.T) {
			if !ValidZone(zone) {
				t.Fatalf("canonical zone rejected: %s", zone)
			}
			r := fixture()
			value := string(zone)
			r.Events[0].Zone = &value
			data, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := Decode(data); err != nil {
				t.Fatalf("Decode rejected canonical zone %s: %v", zone, err)
			}
		})
	}
}

func TestRejectNonCanonicalZones(t *testing.T) {
	for _, zone := range []string{"out_behind", "mystery", ""} {
		t.Run(zone, func(t *testing.T) {
			r := fixture()
			r.Events[0].Zone = &zone
			data, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := Decode(data); err == nil {
				t.Fatalf("expected invalid zone %q to be rejected", zone)
			}
		})
	}
}

func TestEmptyEventsValid(t *testing.T) {
	r := fixture()
	r.Events = []Event{}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(data)
	if err != nil || len(got.AcceptedRecords()) != 0 {
		t.Fatalf("empty events: %v", err)
	}
}

func TestRejectInvalidConfidenceAndBounds(t *testing.T) {
	tests := map[string]func(*Result){
		"confidence": func(r *Result) { value := 1.2; r.Events[0].Confidence = &value },
		"image point": func(r *Result) { r.Events[0].ImagePoint = &Point{1.01, 0.5} },
		"timestamp":   func(r *Result) { r.Events[0].TimestampMS = 10001 },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			r := fixture()
			mutate(&r)
			data, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := Decode(data); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestRejectedAndUnreviewedNotMapped(t *testing.T) {
	for _, status := range []string{"needs_review", "rejected", "unresolved"} {
		t.Run(status, func(t *testing.T) {
			r := fixture()
			r.Events[0].ReviewStatus = status
			if len(r.AcceptedRecords()) != 0 {
				t.Fatalf("%s event mapped as accepted", status)
			}
		})
	}
}

func TestNoisyConfidenceRejected(t *testing.T) {
	r := fixture()
	value := -0.01
	r.Events[0].Confidence = &value
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(data); err == nil {
		t.Fatal("expected confidence rejection")
	}
}

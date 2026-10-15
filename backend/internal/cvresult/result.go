// Package cvresult validates and maps versioned CV bounce job results.
package cvresult

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
)

const SchemaVersion = "1.0"

var ErrInvalidResult = errors.New("invalid CV result")

// Zone is the canonical six-zone taxonomy shared with TennisCore's classifier.
type Zone string

const (
	ZoneFrontCourtLeft  Zone = "front_court_left"
	ZoneFrontCourtRight Zone = "front_court_right"
	ZoneBaselineLeft    Zone = "baseline_left"
	ZoneBaselineRight   Zone = "baseline_right"
	ZoneOutLeft         Zone = "out_left"
	ZoneOutRight        Zone = "out_right"
)

type Point struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}
type Video struct {
	DurationMS int64   `json:"duration_ms"`
	Width      int     `json:"width"`
	Height     int     `json:"height"`
	FPS        float64 `json:"fps"`
}
type Model struct {
	Name    string  `json:"name"`
	Version string  `json:"version"`
	Runtime string  `json:"runtime"`
	SHA256  *string `json:"sha256,omitempty"`
}
type Event struct {
	EventID     string   `json:"event_id"`
	EventType   string   `json:"event_type"`
	TimestampMS int64    `json:"timestamp_ms"`
	ImagePoint  *Point   `json:"image_point"`
	CourtPoint  *Point   `json:"court_point"`
	Zone        *string  `json:"zone"`
	Confidence  *float64 `json:"confidence"`
	ReviewStatus string  `json:"review_status"`
}
type Result struct {
	SchemaVersion string  `json:"schema_version"`
	MatchID       string  `json:"match_id"`
	Video         Video   `json:"video"`
	CalibrationID string  `json:"calibration_id"`
	Model         Model   `json:"model"`
	Events        []Event `json:"events"`
}

// Decode rejects unsupported versions, invalid ranges, duplicate IDs, and malformed event metadata.
func Decode(data []byte) (Result, error) {
	var r Result
	d := json.NewDecoder(strings.NewReader(string(data)))
	d.DisallowUnknownFields()
	if err := d.Decode(&r); err != nil {
		return r, fmt.Errorf("%w: %v", ErrInvalidResult, err)
	}
	if r.SchemaVersion != SchemaVersion || r.MatchID == "" || r.CalibrationID == "" {
		return r, fmt.Errorf("%w: unsupported version or missing IDs", ErrInvalidResult)
	}
	if r.Video.DurationMS <= 0 || r.Video.Width <= 0 || r.Video.Height <= 0 || !finite(r.Video.FPS) || r.Video.FPS <= 0 {
		return r, fmt.Errorf("%w: invalid video metadata", ErrInvalidResult)
	}
	if r.Model.Name == "" || r.Model.Version == "" || r.Model.Runtime == "" {
		return r, fmt.Errorf("%w: missing model metadata", ErrInvalidResult)
	}
	seen := map[string]bool{}
	for _, e := range r.Events {
		if e.EventID == "" || seen[e.EventID] || e.EventType != "bounce" {
			return r, fmt.Errorf("%w: duplicate/empty ID or unsupported event type", ErrInvalidResult)
		}
		seen[e.EventID] = true
		if e.TimestampMS < 0 || e.TimestampMS > r.Video.DurationMS {
			return r, fmt.Errorf("%w: timestamp out of video bounds", ErrInvalidResult)
		}
		if e.ImagePoint != nil && !normalized(*e.ImagePoint) {
			return r, fmt.Errorf("%w: image point outside [0,1]", ErrInvalidResult)
		}
		if e.CourtPoint != nil && (!finite(e.CourtPoint.X) || !finite(e.CourtPoint.Y)) {
			return r, fmt.Errorf("%w: non-finite court point", ErrInvalidResult)
		}
		if e.Confidence != nil && (!finite(*e.Confidence) || *e.Confidence < 0 || *e.Confidence > 1) {
			return r, fmt.Errorf("%w: confidence outside [0,1]", ErrInvalidResult)
		}
		if e.Zone != nil && !ValidZone(Zone(*e.Zone)) {
			return r, fmt.Errorf("%w: unknown zone", ErrInvalidResult)
		}
		switch e.ReviewStatus {
		case "needs_review", "accepted", "corrected", "rejected", "unresolved":
		default:
			return r, fmt.Errorf("%w: unknown review status", ErrInvalidResult)
		}
	}
	return r, nil
}

// ValidZone reports whether z is one of the canonical six tennis zones.
func ValidZone(z Zone) bool {
	switch z {
	case ZoneFrontCourtLeft, ZoneFrontCourtRight, ZoneBaselineLeft, ZoneBaselineRight, ZoneOutLeft, ZoneOutRight:
		return true
	default:
		return false
	}
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func normalized(p Point) bool {
	return finite(p.X) && finite(p.Y) && p.X >= 0 && p.X <= 1 && p.Y >= 0 && p.Y <= 1
}

// AcceptedRecords maps only explicitly reviewed events to existing record fields.
// Unreviewed and rejected events are never persisted as authoritative shots.
type AcceptedRecord struct {
	EventID     string
	TimestampMS int64
	Zone        string
	CourtX      *float64
	CourtY      *float64
	Source      string
}

func (r Result) AcceptedRecords() []AcceptedRecord {
	out := make([]AcceptedRecord, 0)
	for _, e := range r.Events {
		if (e.ReviewStatus != "accepted" && e.ReviewStatus != "corrected") || e.Zone == nil || !ValidZone(Zone(*e.Zone)) {
			continue
		}
		a := AcceptedRecord{EventID: e.EventID, TimestampMS: e.TimestampMS, Zone: *e.Zone, Source: "cv"}
		if e.CourtPoint != nil {
			x, y := e.CourtPoint.X, e.CourtPoint.Y
			a.CourtX, a.CourtY = &x, &y
		}
		out = append(out, a)
	}
	return out
}

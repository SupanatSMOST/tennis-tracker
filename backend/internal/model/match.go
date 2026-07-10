package model

import (
	"time"

	"github.com/google/uuid"
)

// Match represents a single tennis match session owned by a user.
// Nullable columns (Location, PlayedAt, EndedAt) are Go pointers so "absent"
// round-trips as SQL NULL and JSON null. No JSON tags — wire DTOs live in the
// handler package (mirroring model/user.go). VideoRef is intentionally omitted
// (FR-B6: never read or written in this slice).
type Match struct {
	MatchID      uuid.UUID
	UserID       uuid.UUID
	Location     *string    // nullable (OQ-9)
	CourtSurface string     // required, validated app-side
	PlayedAt     *time.Time // nullable (OQ-9); RFC3339 on the wire
	EndedAt      *time.Time // NULL until POST .../end
	CreatedAt    time.Time  // DB DEFAULT now()
}

// Record represents a single shot recorded during a match. CourtX, CourtY, and
// TsMs are nullable to support shots captured without position or timing data
// (FR-V4).
type Record struct {
	RecordID  uuid.UUID
	MatchID   uuid.UUID
	Zone      string     // required non-empty; NOT taxonomy-validated (FR-V3)
	CourtX    *float32   // REAL, nullable (FR-V4)
	CourtY    *float32   // REAL, nullable (FR-V4)
	TsMs      *int32     // INTEGER, nullable (FR-V4)
	Source    string     // validated {cv,manual}; defaults 'manual' (OQ-7)
	CreatedAt time.Time  // DB DEFAULT now()
}

// SummaryRow holds an aggregated shot count for a single zone within a match.
// Rows are written by RebuildSummary and never live-computed at read time (FR-S4).
type SummaryRow struct {
	Zone       string
	ShotCount  int
	ComputedAt time.Time
}

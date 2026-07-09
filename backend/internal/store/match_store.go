package store

import "errors"

// ErrMatchNotFound is returned when a match does not exist or is not owned by
// the requesting user. Unknown and not-owned are intentionally indistinguishable
// to prevent existence leaks (AC-Z1, FR-Z1).
var ErrMatchNotFound = errors.New("match not found")

// ErrMatchAlreadyEnded is returned when a mutation is attempted on a match whose
// ended_at is already set (OQ-2: ended_at is immutable once written; OQ-3:
// shots cannot be added after the match ends).
var ErrMatchAlreadyEnded = errors.New("match already ended")

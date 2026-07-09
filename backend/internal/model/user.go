package model

import (
	"time"

	"github.com/google/uuid"
)

// User holds authentication credentials. No json tags — PasswordHash must
// never be marshaled to the wire. Client-facing DTOs live in the handler package.
type User struct {
	UserID       uuid.UUID
	Username     string
	PasswordHash string
	CreatedAt    time.Time
}

// Profile holds the public-facing user profile. AvatarURL is nullable.
type Profile struct {
	UserID      uuid.UUID
	DisplayName string
	AvatarURL   *string
	UpdatedAt   time.Time
}

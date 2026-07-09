package config

import (
	"fmt"
	"os"
)

// Config holds all runtime configuration loaded from environment variables.
type Config struct {
	DatabaseURL   string // DATABASE_URL   (required)
	JWTSigningKey []byte // JWT_SIGNING_KEY (required, non-empty)
	Port          string // PORT           (optional, default "8080")
}

// Load reads configuration from environment variables.
// Returns an error naming the missing variable if DATABASE_URL or JWT_SIGNING_KEY
// is absent or empty. Never logs the signing key.
func Load() (Config, error) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}

	jwtKey := os.Getenv("JWT_SIGNING_KEY")
	if jwtKey == "" {
		return Config{}, fmt.Errorf("JWT_SIGNING_KEY is required")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	return Config{
		DatabaseURL:   dbURL,
		JWTSigningKey: []byte(jwtKey),
		Port:          port,
	}, nil
}

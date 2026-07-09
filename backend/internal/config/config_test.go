package config

import (
	"bytes"
	"strings"
	"testing"
)

func TestLoad(t *testing.T) {
	tests := []struct {
		name            string
		databaseURL     string
		jwtSigningKey   string
		port            string
		setPort         bool
		wantErr         bool
		wantErrContains string
		wantDatabaseURL string
		wantJWTKey      []byte
		wantPort        string
	}{
		{
			name:            "missing DATABASE_URL (empty)",
			databaseURL:     "",
			jwtSigningKey:   "some-secret",
			port:            "",
			setPort:         false,
			wantErr:         true,
			wantErrContains: "DATABASE_URL",
		},
		{
			name:            "missing JWT_SIGNING_KEY (empty)",
			databaseURL:     "postgres://localhost/test",
			jwtSigningKey:   "",
			port:            "",
			setPort:         false,
			wantErr:         true,
			wantErrContains: "JWT_SIGNING_KEY",
		},
		{
			name:            "all required vars set, PORT unset → default 8080",
			databaseURL:     "postgres://localhost/testdb",
			jwtSigningKey:   "supersecretkey",
			port:            "",
			setPort:         false,
			wantErr:         false,
			wantDatabaseURL: "postgres://localhost/testdb",
			wantJWTKey:      []byte("supersecretkey"),
			wantPort:        "8080",
		},
		{
			name:            "all required vars set, PORT explicitly set",
			databaseURL:     "postgres://localhost/testdb",
			jwtSigningKey:   "supersecretkey",
			port:            "9090",
			setPort:         true,
			wantErr:         false,
			wantDatabaseURL: "postgres://localhost/testdb",
			wantJWTKey:      []byte("supersecretkey"),
			wantPort:        "9090",
		},
		{
			name:            "both DATABASE_URL and JWT_SIGNING_KEY empty → DATABASE_URL error first",
			databaseURL:     "",
			jwtSigningKey:   "",
			port:            "",
			setPort:         false,
			wantErr:         true,
			wantErrContains: "DATABASE_URL",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set all three env vars explicitly so each subtest is hermetic;
			// t.Setenv restores the original value after the test.
			t.Setenv("DATABASE_URL", tt.databaseURL)
			t.Setenv("JWT_SIGNING_KEY", tt.jwtSigningKey)
			if tt.setPort {
				t.Setenv("PORT", tt.port)
			} else {
				t.Setenv("PORT", "") // ensure PORT is empty (default path)
			}

			got, err := Load()

			if tt.wantErr {
				if err == nil {
					t.Fatalf("Load() expected error containing %q, got nil", tt.wantErrContains)
				}
				if tt.wantErrContains != "" && !strings.Contains(err.Error(), tt.wantErrContains) {
					t.Errorf("Load() error = %q, want it to contain %q", err.Error(), tt.wantErrContains)
				}
				return
			}

			if err != nil {
				t.Fatalf("Load() unexpected error: %v", err)
			}

			if got.DatabaseURL != tt.wantDatabaseURL {
				t.Errorf("DatabaseURL = %q, want %q", got.DatabaseURL, tt.wantDatabaseURL)
			}
			if !bytes.Equal(got.JWTSigningKey, tt.wantJWTKey) {
				t.Errorf("JWTSigningKey = %q, want %q", got.JWTSigningKey, tt.wantJWTKey)
			}
			if got.Port != tt.wantPort {
				t.Errorf("Port = %q, want %q", got.Port, tt.wantPort)
			}
		})
	}
}

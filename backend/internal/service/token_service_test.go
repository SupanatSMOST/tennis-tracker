package service

import (
	"crypto/rand"
	"crypto/rsa"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// signingKey is the HS256 key used by the service under test.
var signingKey = []byte("test-signing-key-for-unit-tests")

// TestTokenService_RoundTrip verifies that Issue then Parse returns the
// same UUID (AC15 — sub claim carries the user_id).
func TestTokenService_RoundTrip(t *testing.T) {
	svc := NewTokenService(signingKey)
	id := uuid.New()

	tok, err := svc.Issue(id)
	if err != nil {
		t.Fatalf("Issue() unexpected error: %v", err)
	}
	if tok == "" {
		t.Fatal("Issue() returned empty token")
	}

	got, err := svc.Parse(tok)
	if err != nil {
		t.Fatalf("Parse() unexpected error: %v", err)
	}
	if got != id {
		t.Errorf("Parse() = %v, want %v", got, id)
	}
}

// TestTokenService_NoExpClaim verifies that issued tokens carry no exp
// claim (AC15 / FR-A3 — non-expiring requirement).
func TestTokenService_NoExpClaim(t *testing.T) {
	svc := NewTokenService(signingKey)
	id := uuid.New()

	tok, err := svc.Issue(id)
	if err != nil {
		t.Fatalf("Issue() unexpected error: %v", err)
	}

	// Re-parse independently to inspect raw claims (not through service's Parse
	// which returns only the UUID, discarding claim visibility).
	parsed, err := jwt.Parse(
		tok,
		func(t *jwt.Token) (any, error) { return signingKey, nil },
		jwt.WithValidMethods([]string{"HS256"}),
	)
	if err != nil {
		t.Fatalf("raw jwt.Parse() error: %v", err)
	}

	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		t.Fatal("expected jwt.MapClaims")
	}
	if _, hasExp := claims["exp"]; hasExp {
		t.Error("issued token must NOT contain an exp claim (AC15 / FR-A3)")
	}
}

// TestTokenService_Parse_Rejections groups all Parse-rejection cases into a
// table so each guard is independently verifiable (AC17).
func TestTokenService_Parse_Rejections(t *testing.T) {
	svc := NewTokenService(signingKey)

	// Build an alg:none token.
	noneToken := jwt.NewWithClaims(jwt.SigningMethodNone, jwt.MapClaims{
		"sub": uuid.New().String(),
	})
	noneStr, err := noneToken.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("alg:none token construction failed: %v", err)
	}

	// Build an RS256-signed token using an in-test RSA key.
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("RSA key generation failed: %v", err)
	}
	rs256Token := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"sub": uuid.New().String(),
	})
	rs256Str, err := rs256Token.SignedString(rsaKey)
	if err != nil {
		t.Fatalf("RS256 token construction failed: %v", err)
	}

	// Build a token signed with the correct key but a non-UUID sub.
	nonUUIDToken := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": "not-a-uuid",
	})
	nonUUIDStr, err := nonUUIDToken.SignedString(signingKey)
	if err != nil {
		t.Fatalf("non-UUID sub token construction failed: %v", err)
	}

	// Build a token signed with a different key.
	otherKey := []byte("completely-different-key-xxxxxxxxxxx")
	wrongKeyToken := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": uuid.New().String(),
	})
	wrongKeyStr, err := wrongKeyToken.SignedString(otherKey)
	if err != nil {
		t.Fatalf("wrong-key token construction failed: %v", err)
	}

	tests := []struct {
		name         string
		tokenStr     string
		errSubstring string // non-empty → check error message contains this
	}{
		{
			name:         "wrong key",
			tokenStr:     wrongKeyStr,
			errSubstring: "parse",
		},
		{
			name:         "alg:none",
			tokenStr:     noneStr,
			errSubstring: "parse",
		},
		{
			name:         "RS256 algorithm confusion",
			tokenStr:     rs256Str,
			errSubstring: "parse",
		},
		{
			name:         "malformed garbage",
			tokenStr:     "this.is.not.a.jwt",
			errSubstring: "parse",
		},
		{
			name:         "non-UUID sub claim",
			tokenStr:     nonUUIDStr,
			errSubstring: "UUID",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			got, err := svc.Parse(tt.tokenStr)
			if err == nil {
				t.Errorf("Parse() expected an error, got nil (returned UUID: %v)", got)
				return
			}
			if got != uuid.Nil {
				t.Errorf("Parse() on error should return uuid.Nil, got %v", got)
			}
			if tt.errSubstring != "" && !strings.Contains(err.Error(), tt.errSubstring) {
				t.Errorf("Parse() error = %q, want substring %q", err.Error(), tt.errSubstring)
			}
		})
	}
}

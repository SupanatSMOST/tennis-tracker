package service

import (
	"errors"
	"fmt"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// TokenService issues and verifies HS256 JWTs whose subject is a user UUID.
// Tokens carry no exp claim and do not expire.
type TokenService struct {
	key []byte
}

// NewTokenService constructs a TokenService using the given signing key.
func NewTokenService(key []byte) *TokenService {
	return &TokenService{key: key}
}

// Issue creates a signed HS256 JWT with claim sub = userID.String() and no exp.
func (s *TokenService) Issue(userID uuid.UUID) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": userID.String(),
	})
	signed, err := token.SignedString(s.key)
	if err != nil {
		return "", fmt.Errorf("token_service: sign: %w", err)
	}
	return signed, nil
}

// Parse verifies the token's HS256 signature and returns the sub UUID.
// It rejects: wrong key, alg:none, any non-HS256 algorithm, malformed tokens,
// and tokens whose sub is not a valid UUID.
func (s *TokenService) Parse(tokenString string) (uuid.UUID, error) {
	token, err := jwt.Parse(
		tokenString,
		func(t *jwt.Token) (any, error) {
			// Defense-in-depth: assert method is *jwt.SigningMethodHMAC
			// even though jwt.WithValidMethods already filters alg != "HS256".
			// This blocks alg:none (which has method *jwt.signingMethodNone, not HMAC)
			// and RS/HS confusion attacks.
			if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, fmt.Errorf("token_service: unexpected signing method: %v", t.Header["alg"])
			}
			return s.key, nil
		},
		jwt.WithValidMethods([]string{"HS256"}),
	)
	if err != nil {
		return uuid.Nil, fmt.Errorf("token_service: parse: %w", err)
	}
	if !token.Valid {
		return uuid.Nil, errors.New("token_service: invalid token")
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return uuid.Nil, errors.New("token_service: unexpected claims type")
	}

	subVal, exists := claims["sub"]
	if !exists {
		return uuid.Nil, errors.New("token_service: missing sub claim")
	}
	subStr, ok := subVal.(string)
	if !ok {
		return uuid.Nil, errors.New("token_service: sub claim is not a string")
	}

	id, err := uuid.Parse(subStr)
	if err != nil {
		return uuid.Nil, fmt.Errorf("token_service: sub is not a valid UUID: %w", err)
	}

	return id, nil
}

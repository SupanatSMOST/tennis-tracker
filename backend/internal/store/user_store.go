package store

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/model"
)

// ErrUsernameTaken is returned by CreateUserWithProfile when the username is
// already in use (Postgres unique violation code 23505).
var ErrUsernameTaken = errors.New("username already taken")

// ErrUserNotFound is returned by GetUserByUsername and GetUserByID when no
// matching row exists.
var ErrUserNotFound = errors.New("user not found")

// CreateUserWithProfile inserts a user_login row and a matching profile row
// inside a single transaction. It does not set created_at (DB DEFAULT now()).
// A duplicate username returns ErrUsernameTaken; the transaction is rolled back
// so neither table is left with a partial row.
func (s *Store) CreateUserWithProfile(ctx context.Context, u model.User) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit; intentional

	_, err = tx.Exec(ctx,
		`INSERT INTO user_login (user_id, username, password_hash)
		 VALUES ($1, $2, $3)`,
		u.UserID, u.Username, u.PasswordHash,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return ErrUsernameTaken
		}
		return err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO profile (user_id, display_name, avatar_url)
		 VALUES ($1, $2, $3)`,
		u.UserID, u.Username, nil,
	)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// GetUserByUsername retrieves the user_login row matching username.
// Returns ErrUserNotFound when no row exists.
func (s *Store) GetUserByUsername(ctx context.Context, username string) (model.User, error) {
	var u model.User
	err := s.pool.QueryRow(ctx,
		`SELECT user_id, username, password_hash, created_at
		 FROM user_login
		 WHERE username = $1`,
		username,
	).Scan(&u.UserID, &u.Username, &u.PasswordHash, &u.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return model.User{}, ErrUserNotFound
		}
		return model.User{}, err
	}
	return u, nil
}

// GetUserByID retrieves the user_login row matching id.
// Returns ErrUserNotFound when no row exists.
func (s *Store) GetUserByID(ctx context.Context, id uuid.UUID) (model.User, error) {
	var u model.User
	err := s.pool.QueryRow(ctx,
		`SELECT user_id, username, password_hash, created_at
		 FROM user_login
		 WHERE user_id = $1`,
		id,
	).Scan(&u.UserID, &u.Username, &u.PasswordHash, &u.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return model.User{}, ErrUserNotFound
		}
		return model.User{}, err
	}
	return u, nil
}

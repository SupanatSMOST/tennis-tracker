package store

import "github.com/jackc/pgx/v5/pgxpool"

// Store wraps a pgx connection pool. All query methods live on *Store so the
// pool is never accessed directly from handler or service packages.
type Store struct {
	pool *pgxpool.Pool
}

// New constructs a Store from an already-opened pool. Pool construction from
// DATABASE_URL (pgxpool.New) is the caller's responsibility (main — Task 12).
func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

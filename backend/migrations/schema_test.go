package migrations_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// openPool connects to DATABASE_URL or skips if the var is unset/empty.
func openPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set — skipping DB integration tests")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	if err := pool.Ping(context.Background()); err != nil {
		t.Fatalf("DB ping failed: %v", err)
	}
	return pool
}

// tableExists queries information_schema.tables.
func tableExists(ctx context.Context, pool *pgxpool.Pool, tableName string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = $1
		)`, tableName).Scan(&exists)
	return exists, err
}

// columnInfo holds basic metadata about a single column.
type columnInfo struct {
	dataType   string
	isNullable string // "YES" or "NO"
}

// getColumnInfo queries information_schema.columns for a specific column.
func getColumnInfo(ctx context.Context, pool *pgxpool.Pool, table, column string) (columnInfo, error) {
	var ci columnInfo
	err := pool.QueryRow(ctx,
		`SELECT data_type, is_nullable
		 FROM information_schema.columns
		 WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
		table, column).Scan(&ci.dataType, &ci.isNullable)
	if errors.Is(err, pgx.ErrNoRows) {
		return ci, fmt.Errorf("column %s.%s not found", table, column)
	}
	return ci, err
}

// pkColumns returns the set of column names that form the PK for a table.
func pkColumns(ctx context.Context, pool *pgxpool.Pool, table string) ([]string, error) {
	rows, err := pool.Query(ctx, `
		SELECT kcu.column_name
		FROM information_schema.table_constraints tc
		JOIN information_schema.key_column_usage kcu
		  ON tc.constraint_name = kcu.constraint_name
		 AND tc.table_schema    = kcu.table_schema
		WHERE tc.constraint_type = 'PRIMARY KEY'
		  AND tc.table_schema    = 'public'
		  AND tc.table_name      = $1
		ORDER BY kcu.ordinal_position`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		cols = append(cols, c)
	}
	return cols, rows.Err()
}

// fkExists checks whether a specific FK constraint exists in pg_catalog.
func fkExists(ctx context.Context, pool *pgxpool.Pool, childTable, childCol, parentTable, parentCol string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM pg_constraint c
			JOIN pg_class     child_rel  ON child_rel.oid  = c.conrelid
			JOIN pg_class     parent_rel ON parent_rel.oid = c.confrelid
			JOIN pg_attribute child_att  ON child_att.attrelid  = c.conrelid
			                            AND child_att.attnum     = ANY(c.conkey)
			JOIN pg_attribute parent_att ON parent_att.attrelid  = c.confrelid
			                            AND parent_att.attnum     = ANY(c.confkey)
			JOIN pg_namespace ns         ON ns.oid = child_rel.relnamespace
			WHERE c.contype            = 'f'
			  AND ns.nspname           = 'public'
			  AND child_rel.relname    = $1
			  AND child_att.attname    = $2
			  AND parent_rel.relname   = $3
			  AND parent_att.attname   = $4
		)`, childTable, childCol, parentTable, parentCol).Scan(&exists)
	return exists, err
}

// columnExists checks whether a column is present on a table.
func columnExists(ctx context.Context, pool *pgxpool.Pool, table, column string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
		)`, table, column).Scan(&exists)
	return exists, err
}

// ────────────────────────────────────────────────────────────────────────────

// TestSchema_AC2_AllFiveTablesExist verifies AC2: all five tables are present.
func TestSchema_AC2_AllFiveTablesExist(t *testing.T) {
	pool := openPool(t)
	ctx := context.Background()

	tables := []string{"user_login", "profile", "match", "record", "match_summary"}
	for _, tbl := range tables {
		t.Run(tbl, func(t *testing.T) {
			ok, err := tableExists(ctx, pool, tbl)
			if err != nil {
				t.Fatalf("tableExists(%q): %v", tbl, err)
			}
			if !ok {
				t.Errorf("table %q does not exist", tbl)
			}
		})
	}
}

// TestSchema_AC3_KeyColumnTypes verifies AC3 spot-check: key columns exist with
// correct data types and nullability.
func TestSchema_AC3_KeyColumnTypes(t *testing.T) {
	pool := openPool(t)
	ctx := context.Background()

	type check struct {
		table        string
		column       string
		wantType     string
		wantNullable string // "YES" or "NO"
	}
	checks := []check{
		// user_login
		{"user_login", "user_id", "uuid", "NO"},
		{"user_login", "username", "text", "NO"},
		{"user_login", "password_hash", "text", "NO"},
		{"user_login", "created_at", "timestamp with time zone", "NO"},
		// profile
		{"profile", "user_id", "uuid", "NO"},
		{"profile", "display_name", "text", "NO"},
		{"profile", "avatar_url", "text", "YES"}, // nullable
		{"profile", "updated_at", "timestamp with time zone", "NO"},
		// match
		{"match", "match_id", "uuid", "NO"},
		{"match", "user_id", "uuid", "NO"},
		// record — AC3 focus
		{"record", "court_x", "real", "YES"}, // REAL nullable
		{"record", "court_y", "real", "YES"}, // REAL nullable
		{"record", "zone", "text", "YES"},    // TEXT (no CHECK)
		// match_summary — AC3 focus
		{"match_summary", "match_id", "uuid", "NO"},
		{"match_summary", "zone", "text", "NO"},
		{"match_summary", "shot_count", "integer", "NO"},
	}

	for _, c := range checks {
		t.Run(c.table+"."+c.column, func(t *testing.T) {
			ci, err := getColumnInfo(ctx, pool, c.table, c.column)
			if err != nil {
				t.Fatalf("getColumnInfo(%q,%q): %v", c.table, c.column, err)
			}
			if ci.dataType != c.wantType {
				t.Errorf("data_type = %q, want %q", ci.dataType, c.wantType)
			}
			if ci.isNullable != c.wantNullable {
				t.Errorf("is_nullable = %q, want %q", ci.isNullable, c.wantNullable)
			}
		})
	}
}

// TestSchema_AC4_UsernameUnique verifies AC4: username UNIQUE constraint; inserting
// two rows with the same username fails with a 23505 violation. The transaction is
// rolled back so no data is left behind.
func TestSchema_AC4_UsernameUnique(t *testing.T) {
	pool := openPool(t)
	ctx := context.Background()

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// First insert — must succeed.
	_, err = tx.Exec(ctx,
		`INSERT INTO user_login (user_id, username, password_hash)
		 VALUES (gen_random_uuid(), 'test_unique_user', 'hash1')`)
	if err != nil {
		t.Fatalf("first INSERT failed unexpectedly: %v", err)
	}

	// Second insert — same username, must fail with 23505.
	_, err = tx.Exec(ctx,
		`INSERT INTO user_login (user_id, username, password_hash)
		 VALUES (gen_random_uuid(), 'test_unique_user', 'hash2')`)
	if err == nil {
		t.Fatal("second INSERT with duplicate username succeeded; expected unique violation")
	}

	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		t.Fatalf("expected *pgconn.PgError, got %T: %v", err, err)
	}
	if pgErr.Code != "23505" {
		t.Errorf("pg error code = %q, want 23505 (unique_violation)", pgErr.Code)
	}
	// Rollback is deferred — no rows escape.
}

// TestSchema_AC5_MatchSummaryCompositePK verifies AC5: composite PK (match_id, zone)
// and no surrogate id column.
func TestSchema_AC5_MatchSummaryCompositePK(t *testing.T) {
	pool := openPool(t)
	ctx := context.Background()

	cols, err := pkColumns(ctx, pool, "match_summary")
	if err != nil {
		t.Fatalf("pkColumns: %v", err)
	}

	// Must be exactly {match_id, zone} in that order.
	want := []string{"match_id", "zone"}
	if len(cols) != len(want) {
		t.Fatalf("PK columns = %v, want %v", cols, want)
	}
	for i, c := range want {
		if cols[i] != c {
			t.Errorf("PK column[%d] = %q, want %q", i, cols[i], c)
		}
	}

	// No surrogate id column should exist.
	for _, surrogateCol := range []string{"id", "match_summary_id"} {
		ok, err := columnExists(ctx, pool, "match_summary", surrogateCol)
		if err != nil {
			t.Fatalf("columnExists(%q): %v", surrogateCol, err)
		}
		if ok {
			t.Errorf("surrogate column %q found on match_summary; spec forbids it", surrogateCol)
		}
	}
}

// TestSchema_AC6_ForeignKeys verifies AC6: all four declared FKs exist.
func TestSchema_AC6_ForeignKeys(t *testing.T) {
	pool := openPool(t)
	ctx := context.Background()

	type fk struct {
		childTable  string
		childCol    string
		parentTable string
		parentCol   string
	}
	fks := []fk{
		{"profile", "user_id", "user_login", "user_id"},
		{"match", "user_id", "user_login", "user_id"},
		{"record", "match_id", "match", "match_id"},
		{"match_summary", "match_id", "match", "match_id"},
	}

	for _, f := range fks {
		name := fmt.Sprintf("%s.%s→%s.%s", f.childTable, f.childCol, f.parentTable, f.parentCol)
		t.Run(name, func(t *testing.T) {
			ok, err := fkExists(ctx, pool, f.childTable, f.childCol, f.parentTable, f.parentCol)
			if err != nil {
				t.Fatalf("fkExists: %v", err)
			}
			if !ok {
				t.Errorf("FK %s not found in pg_catalog", name)
			}
		})
	}
}

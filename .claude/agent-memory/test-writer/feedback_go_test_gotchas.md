---
name: feedback-go-test-gotchas
description: Go test pitfalls for this project: []byte comparison, t.Setenv parallelism, hermetic env, error-message discrimination
metadata:
  type: feedback
---

1. **[]byte fields can't use `==`.** `Config.JWTSigningKey` is `[]byte`; use `bytes.Equal()` or `reflect.DeepEqual` on the struct. Using `!=` won't compile.

**Why:** Go struct equality with slice fields doesn't compile.

**How to apply:** Any time a struct under test has a slice field, switch to field-by-field comparison with `bytes.Equal`.

2. **Never `t.Parallel()` with `t.Setenv`.** `t.Setenv` panics if the test or any parent subtest is marked parallel.

**Why:** Go's test framework enforces this to prevent concurrent env mutation.

**How to apply:** Keep all env-manipulation tests serial; do not add `t.Parallel()` to any test or subtest that calls `t.Setenv`.

3. **Make each subtest hermetic — set ALL env vars explicitly.** The dev's shell may have `DATABASE_URL` exported (e.g. for goose). Use `t.Setenv("DATABASE_URL", "")` to simulate "missing" — `Load()` only checks `== ""` so unset and empty are the same path.

**Why:** Ambient env vars leak into tests, causing false passes.

**How to apply:** In every subtest row, explicitly set all three env vars (DATABASE_URL, JWT_SIGNING_KEY, PORT).

4. **Discriminate which var caused the error by asserting the error message substring.** `wantErr bool` alone doesn't verify the right var failed — `Load()` short-circuits on DATABASE_URL, so "missing JWT_SIGNING_KEY" must set DATABASE_URL to a non-empty value AND assert `strings.Contains(err.Error(), "JWT_SIGNING_KEY")`.

**Why:** Without substring assertion, the test passes for the wrong reason (DATABASE_URL error instead of JWT_SIGNING_KEY error).

**How to apply:** Add `wantErrContains string` column to table tests for env-validation functions.

5. **After a failed Postgres statement the tx is in aborted state — just Rollback, no more queries.** For unique-constraint tests: insert row1 (ok), insert row2 same key (fails with 23505), then `defer tx.Rollback(ctx)`. Assert `errors.As(err, &pgErr)` and `pgErr.Code == "23505"`. Don't try to query inside the aborted tx.

**Why:** Postgres puts the connection in error state after any statement failure; further queries in the same tx return "current transaction is aborted".

**How to apply:** For any AC test that deliberately causes a constraint violation, use a single `defer tx.Rollback` and don't issue any query after the expected-to-fail statement.

7. **Integration tests: scope ALL count queries to user_id/username, never bare `count(*)`.** The test DB persists across tasks — an unscoped count will include rows from prior test runs and give false failures.

**Why:** Task 4 schema tests and Task 6 store tests share the same DB. Bare counts are non-idempotent.

**How to apply:** Always `WHERE user_id = $1` or `WHERE username = $1` when asserting row counts.

8. **AC14 rollback test: use a DIFFERENT user_id for the duplicate attempt.** If both creates use the same UUID, the PK constraint fires instead of the UNIQUE constraint — the orphan-profile rollback check becomes vacuous.

**Why:** A same-id second insert hits `user_id` PK (23505 on PK), not the `username` UNIQUE index. The profile row was never written, so the rollback assertion passes trivially.

**How to apply:** In duplicate-username tests, generate `idA = uuid.New()` and `idB = uuid.New()` with `uA.Username == uB.Username` and `uA.UserID != uB.UserID`.

9. **Auth-service integration tests: use `package service_test` (external test package).** The internal `token_service_test.go` is `package service` and declares a package-level `var signingKey`. Adding another `package service` file that redeclares any package-level name causes a compile error.

**Why:** Go allows at most one `_test.go` file per package name at the same scope; name collisions are compile errors.

**How to apply:** When writing integration tests that import the service package from outside (as a black box), use `package service_test`. All exported names (`service.NewAuthService`, `service.ValidationError`, etc.) remain accessible.

10. **Auth integration tests: delete profile before user_login on cleanup.** The FK is `profile.user_id → user_login.user_id` with `ON DELETE NO ACTION`. Deleting user_login first raises a FK violation.

**Why:** Postgres enforces FK referential integrity on delete.

**How to apply:** In `t.Cleanup`, always `DELETE FROM profile WHERE user_id = $1` before `DELETE FROM user_login WHERE user_id = $1`.

11. **Handler-internal tests: use `package handler` (not `handler_test`) to access unexported helpers like `userFromContext`.** Prefix all test helpers with an acronym (e.g. `mw`) to avoid name collisions with existing `package handler` test files.

**Why:** `userFromContext` is unexported; it can only be called from within the same package. Multiple `_test.go` files can share a package name but must not redeclare the same top-level names.

**How to apply:** Use `package handler` when testing middleware that injects/reads unexported context keys. Prefix helper functions with a file-specific prefix so they never collide with helpers in `respond_test.go` or other same-package test files.

6. **information_schema type strings differ from SQL keywords.** `TIMESTAMPTZ` → `"timestamp with time zone"`, `REAL` → `"real"`, `INTEGER` → `"integer"`, `TEXT` → `"text"`, `UUID` → `"uuid"`. `is_nullable` values are `"YES"` / `"NO"` (not booleans).

**Why:** information_schema uses ANSI SQL canonical type names, not PG keywords.

**How to apply:** When asserting column types from `information_schema.columns`, use these strings verbatim.

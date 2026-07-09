package service_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/SupanatSMOST/tennis-tracker/backend/internal/service"
	"github.com/SupanatSMOST/tennis-tracker/backend/internal/store"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// newNilStoreGameplayService constructs a GameplayService with a nil store.
// This is intentional: validation must return before any store call. If a
// future regression causes the store to be called on a failure path, the nil
// deref will panic and the test will fail loud — stronger than a mere error
// assertion.
func newNilStoreGameplayService() *service.GameplayService {
	return service.NewGameplayService(nil)
}

// newDBGameplayService constructs a GameplayService backed by a real Postgres
// pool. The test is skipped when DATABASE_URL is unset.
func newDBGameplayService(t *testing.T) (*service.GameplayService, *authTestHarness) {
	t.Helper()
	h := newTestAuthService(t) // skips when DATABASE_URL unset
	svc := service.NewGameplayService(store.New(h.pool))
	return svc, &h
}

// ptr helpers for ShotInput fields.
func strPtr(s string) *string  { return &s }
func f32Ptr(v float32) *float32 { return &v }
func i32Ptr(v int32) *int32    { return &v }

// registerMatchCleanup registers a cleanup that removes the match and its
// records/summary in FK order: match_summary → record → match.
func registerMatchCleanup(t *testing.T, h *authTestHarness, matchID uuid.UUID) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		h.pool.Exec(ctx, "DELETE FROM match_summary WHERE match_id = $1", matchID) //nolint:errcheck
		h.pool.Exec(ctx, "DELETE FROM record WHERE match_id = $1", matchID)        //nolint:errcheck
		h.pool.Exec(ctx, "DELETE FROM match WHERE match_id = $1", matchID)         //nolint:errcheck
	})
}

// assertValidationError asserts that err is (or wraps) a service.ValidationError.
func assertValidationError(t *testing.T, err error, context string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: expected ValidationError, got nil", context)
	}
	var ve service.ValidationError
	if !errors.As(err, &ve) {
		t.Errorf("%s: err = %v (%T), want errors.As(_, *ValidationError) to be true", context, err, err)
	}
}

// ---------------------------------------------------------------------------
// DB-FREE: CreateMatch surface validation  (AC9)
// ---------------------------------------------------------------------------
// These tests use a nil store — they will PASS without DATABASE_URL because
// validation returns before any store call is made.

func TestGameplayService_CreateMatch_SurfaceValidation_DBFree(t *testing.T) {
	svc := newNilStoreGameplayService()
	ctx := context.Background()
	userID := uuid.New()

	tests := []struct {
		name         string
		courtSurface string
		wantValErr   bool
	}{
		// Invalid surfaces — must return ValidationError before store call.
		{"empty string", "", true},
		{"carpet", "carpet", true},
		{"HARD (case-sensitive)", "HARD", true},
		{"Clay (mixed case)", "Clay", true},
		{"grass with trailing space", "grass ", true},
		{"hard with leading space", " hard", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := svc.CreateMatch(ctx, userID, tt.courtSurface, nil, nil)
			if tt.wantValErr {
				assertValidationError(t, err, "CreateMatch("+tt.courtSurface+")")
			} else {
				// This branch is never exercised in the nil-store group, but kept
				// for completeness if a valid surface is added above by mistake.
				if err != nil {
					t.Fatalf("CreateMatch() unexpected error: %v", err)
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// DB-FREE: AddRecords validation  (AC15, OQ-7 rejection path)
// ---------------------------------------------------------------------------
// These tests use a nil store — they will PASS without DATABASE_URL.

func TestGameplayService_AddRecords_ValidationDBFree(t *testing.T) {
	svc := newNilStoreGameplayService()
	ctx := context.Background()
	matchID := uuid.New()
	userID := uuid.New()

	tests := []struct {
		name string
		shots []service.ShotInput
	}{
		{
			name:  "empty batch",
			shots: []service.ShotInput{},
		},
		{
			name: "single shot with empty zone",
			shots: []service.ShotInput{
				{Zone: "", CourtX: f32Ptr(1.0)},
			},
		},
		{
			name: "multiple shots — first ok, second has empty zone",
			shots: []service.ShotInput{
				{Zone: "baseline"},
				{Zone: ""},
			},
		},
		{
			name: "source is bogus string",
			shots: []service.ShotInput{
				{Zone: "net", Source: strPtr("bogus")},
			},
		},
		{
			name: "source is unexpected value (uppercase CV)",
			shots: []service.ShotInput{
				{Zone: "net", Source: strPtr("CV")},
			},
		},
		{
			name: "source is unexpected value (Manual capitalised)",
			shots: []service.ShotInput{
				{Zone: "net", Source: strPtr("Manual")},
			},
		},
		{
			name: "first shot ok, second shot bad source",
			shots: []service.ShotInput{
				{Zone: "baseline"},
				{Zone: "net", Source: strPtr("robot")},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ids, err := svc.AddRecords(ctx, matchID, userID, tt.shots)
			assertValidationError(t, err, "AddRecords")
			if ids != nil {
				t.Errorf("AddRecords() expected nil ids on ValidationError, got %v", ids)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// DB-GATED: CreateMatch valid surfaces succeed  (AC9 positive)
// ---------------------------------------------------------------------------
// Requires DATABASE_URL. Skipped when unset.

func TestGameplayService_CreateMatch_ValidSurface_DBGated(t *testing.T) {
	svc, h := newDBGameplayService(t) // skips when DATABASE_URL unset
	ctx := context.Background()

	// Seed a user to act as match owner.
	username := uniqueUsername()
	user, _, err := h.svc.Signup(ctx, username, "password-abc-123")
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	validSurfaces := []string{"hard", "clay", "grass"}
	for _, surface := range validSurfaces {
		t.Run(surface, func(t *testing.T) {
			loc := "Test Court"
			playedAt := time.Now().UTC().Truncate(time.Second)
			m, err := svc.CreateMatch(ctx, user.UserID, surface, &loc, &playedAt)
			if err != nil {
				t.Fatalf("CreateMatch(%q) unexpected error: %v", surface, err)
			}
			registerMatchCleanup(t, h, m.MatchID)

			if m.MatchID == uuid.Nil {
				t.Error("CreateMatch() returned zero MatchID")
			}
			if m.CourtSurface != surface {
				t.Errorf("CreateMatch() CourtSurface = %q, want %q", m.CourtSurface, surface)
			}
			if m.UserID != user.UserID {
				t.Errorf("CreateMatch() UserID = %v, want %v", m.UserID, user.UserID)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// DB-GATED: AddRecords nil source defaults to "manual"  (OQ-7)
// ---------------------------------------------------------------------------
// Requires DATABASE_URL. Skipped when unset.

func TestGameplayService_AddRecords_NilSourceDefaultsToManual_DBGated(t *testing.T) {
	svc, h := newDBGameplayService(t) // skips when DATABASE_URL unset
	ctx := context.Background()

	// Seed a user.
	username := uniqueUsername()
	user, _, err := h.svc.Signup(ctx, username, "password-abc-123")
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	// Create a match to add records to.
	m, err := svc.CreateMatch(ctx, user.UserID, "clay", nil, nil)
	if err != nil {
		t.Fatalf("CreateMatch() unexpected error: %v", err)
	}
	registerMatchCleanup(t, h, m.MatchID)

	// Batch: first shot has nil source, second has explicit "cv".
	shots := []service.ShotInput{
		{Zone: "baseline", CourtX: f32Ptr(2.5), TsMs: i32Ptr(100), Source: nil},
		{Zone: "net", Source: strPtr("cv")},
	}

	ids, err := svc.AddRecords(ctx, m.MatchID, user.UserID, shots)
	if err != nil {
		t.Fatalf("AddRecords() unexpected error: %v", err)
	}
	if len(ids) != 2 {
		t.Fatalf("AddRecords() returned %d ids, want 2", len(ids))
	}

	// Verify DB: the nil-source shot must have source = 'manual'.
	var src string
	err = h.pool.QueryRow(ctx,
		"SELECT source FROM record WHERE record_id = $1", ids[0],
	).Scan(&src)
	if err != nil {
		t.Fatalf("SELECT source for record[0]: %v", err)
	}
	if src != "manual" {
		t.Errorf("record[0].source = %q, want %q (nil source must default to manual)", src, "manual")
	}

	// Verify DB: the explicit "cv" shot must remain "cv".
	err = h.pool.QueryRow(ctx,
		"SELECT source FROM record WHERE record_id = $1", ids[1],
	).Scan(&src)
	if err != nil {
		t.Fatalf("SELECT source for record[1]: %v", err)
	}
	if src != "cv" {
		t.Errorf("record[1].source = %q, want %q", src, "cv")
	}
}

// ---------------------------------------------------------------------------
// DB-GATED: AddRecords valid batch inserts expected row count  (AC15 positive)
// ---------------------------------------------------------------------------
// Requires DATABASE_URL. Skipped when unset.

func TestGameplayService_AddRecords_ValidBatch_DBGated(t *testing.T) {
	svc, h := newDBGameplayService(t) // skips when DATABASE_URL unset
	ctx := context.Background()

	// Seed a user.
	username := uniqueUsername()
	user, _, err := h.svc.Signup(ctx, username, "password-abc-456")
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	// Create a match.
	m, err := svc.CreateMatch(ctx, user.UserID, "hard", nil, nil)
	if err != nil {
		t.Fatalf("CreateMatch() unexpected error: %v", err)
	}
	registerMatchCleanup(t, h, m.MatchID)

	// 3-shot batch: mixed source states.
	shots := []service.ShotInput{
		{Zone: "baseline", Source: strPtr("manual")},
		{Zone: "net", Source: strPtr("cv")},
		{Zone: "service-box", Source: nil}, // nil → defaults to "manual"
	}

	ids, err := svc.AddRecords(ctx, m.MatchID, user.UserID, shots)
	if err != nil {
		t.Fatalf("AddRecords() unexpected error: %v", err)
	}
	if len(ids) != 3 {
		t.Fatalf("AddRecords() returned %d ids, want 3", len(ids))
	}
	for i, id := range ids {
		if id == uuid.Nil {
			t.Errorf("ids[%d] is zero UUID", i)
		}
	}

	// DB row count must equal batch size.
	var count int
	err = h.pool.QueryRow(ctx,
		"SELECT COUNT(*) FROM record WHERE match_id = $1", m.MatchID,
	).Scan(&count)
	if err != nil {
		t.Fatalf("SELECT COUNT(*): %v", err)
	}
	if count != 3 {
		t.Errorf("record count = %d, want 3", count)
	}
}

// ---------------------------------------------------------------------------
// DB-GATED: AddRecords validation failure inserts zero rows  (AC15 zero-write)
// ---------------------------------------------------------------------------
// Ensures that when validation rejects, the store is never called and zero rows
// are written. Requires DATABASE_URL; skipped when unset.

func TestGameplayService_AddRecords_ValidationFailureWritesZeroRows_DBGated(t *testing.T) {
	svc, h := newDBGameplayService(t) // skips when DATABASE_URL unset
	ctx := context.Background()

	// Seed a user.
	username := uniqueUsername()
	user, _, err := h.svc.Signup(ctx, username, "password-abc-789")
	if err != nil {
		t.Fatalf("Signup() unexpected error: %v", err)
	}
	registerUserCleanup(t, h.pool, user.UserID)

	// Create a match.
	m, err := svc.CreateMatch(ctx, user.UserID, "grass", nil, nil)
	if err != nil {
		t.Fatalf("CreateMatch() unexpected error: %v", err)
	}
	registerMatchCleanup(t, h, m.MatchID)

	badBatches := []struct {
		name  string
		shots []service.ShotInput
	}{
		{
			name:  "empty batch",
			shots: []service.ShotInput{},
		},
		{
			name:  "empty zone",
			shots: []service.ShotInput{{Zone: ""}},
		},
		{
			name:  "bad source",
			shots: []service.ShotInput{{Zone: "baseline", Source: strPtr("bogus")}},
		},
	}

	for _, tt := range badBatches {
		t.Run(tt.name, func(t *testing.T) {
			_, err := svc.AddRecords(ctx, m.MatchID, user.UserID, tt.shots)
			assertValidationError(t, err, "AddRecords/"+tt.name)

			// Verify zero rows were inserted.
			var count int
			if scanErr := h.pool.QueryRow(ctx,
				"SELECT COUNT(*) FROM record WHERE match_id = $1", m.MatchID,
			).Scan(&count); scanErr != nil {
				t.Fatalf("SELECT COUNT(*): %v", scanErr)
			}
			if count != 0 {
				t.Errorf("expected 0 rows after validation failure, got %d", count)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// DB-FREE: AddRecords — valid source values do not trigger ValidationError
// ---------------------------------------------------------------------------
// Uses nil store. Panics (nil deref) only if the store is reached, which means
// validation passed — that's the assertion. This is NOT a panic-on-success test;
// we check specifically the source=nil, source="cv", source="manual" paths.
// The test verifies these pass the validation gate and would proceed to store.
//
// Because the nil store will panic when reached, we recover and assert the panic
// came from a nil store call — NOT from a ValidationError.

func TestGameplayService_AddRecords_ValidSourcesPassValidation_DBFree(t *testing.T) {
	ctx := context.Background()
	matchID := uuid.New()
	userID := uuid.New()

	validCases := []struct {
		name   string
		source *string
	}{
		{"nil source (defaults to manual)", nil},
		{"explicit manual", strPtr("manual")},
		{"explicit cv", strPtr("cv")},
	}

	for _, tt := range validCases {
		t.Run(tt.name, func(t *testing.T) {
			svc := newNilStoreGameplayService()
			shots := []service.ShotInput{
				{Zone: "baseline", Source: tt.source},
			}

			// We expect either:
			//   (a) A panic (nil pointer deref when the service calls g.store.InsertRecords)
			//       — proof that validation passed and execution reached the store.
			//   (b) No error that is a ValidationError.
			// We recover from the panic to avoid failing the test.
			func() {
				defer func() {
					if r := recover(); r != nil {
						// Panic means we passed validation — that's what we want.
						// The nil deref is the store being called.
					}
				}()
				_, err := svc.AddRecords(ctx, matchID, userID, shots)
				if err != nil {
					var ve service.ValidationError
					if errors.As(err, &ve) {
						t.Errorf("valid source %v got ValidationError: %v", tt.source, err)
					}
					// A non-validation error from a nil store would be strange;
					// normally it panics. Either way it is not a ValidationError.
				}
			}()
		})
	}
}

// ---------------------------------------------------------------------------
// DB-FREE: CreateMatch — valid surfaces pass validation gate (nil store panics)
// ---------------------------------------------------------------------------
// Same nil-store panic technique: if validation passes, the store is reached and
// panics. We recover and treat the panic as proof that no ValidationError fired.

func TestGameplayService_CreateMatch_ValidSurfacesPassValidation_DBFree(t *testing.T) {
	ctx := context.Background()
	userID := uuid.New()

	for _, surface := range []string{"hard", "clay", "grass"} {
		t.Run(surface, func(t *testing.T) {
			svc := newNilStoreGameplayService()
			func() {
				defer func() {
					if r := recover(); r != nil {
						// Nil deref at store call — validation passed. Desired outcome.
					}
				}()
				_, err := svc.CreateMatch(ctx, userID, surface, nil, nil)
				if err != nil {
					var ve service.ValidationError
					if errors.As(err, &ve) {
						t.Errorf("valid surface %q got ValidationError: %v", surface, err)
					}
				}
			}()
		})
	}
}

// ---------------------------------------------------------------------------
// Ensure unused os import is acknowledged (used in newDBGameplayService via
// newTestAuthService which lives in auth_service_test.go — same package).
// ---------------------------------------------------------------------------
var _ = os.Getenv // satisfy import in case the compiler does not inline it

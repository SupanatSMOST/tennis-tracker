package handler_test

// End-to-end tests for Task 10: full gameplay HTTP flow + ownership isolation.
//
// These tests boot the real router (real pgxpool → BuildRouter → httptest) and
// drive actual HTTP requests. They cover:
//   - Full happy-path CRUD flow (signup → create → get → list → add records → end → summary)
//   - Bad surface → 400, no row (AC9)
//   - Single + N-batch add → list returns total N in deterministic order (AC13/AC14)
//   - Bad batch cases → 400, zero rows inserted (AC15)
//   - Summary before end → [] (AC20); after end → per-zone counts (AC12/AC17)
//   - Post-end semantics: double-end → 409 (OQ-2); records-on-ended → 409 (OQ-3)
//   - Ownership 404 parity (AC-Z1): byte-identical 404 for cross-user vs nonexistent
//   - No cross-user write (AC-Z2): A's match unchanged after B's failed mutations
//   - 401 before ownership (AC-Z3): missing/invalid token → 401
//   - Unparseable {id} → 404 (indistinguishable)
//
// Requirements: DATABASE_URL must point to the throwaway cluster on port 55432.
// Tests t.Skip when the var is absent.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ── additional helpers ────────────────────────────────────────────────────────

// e2ePostAuth sends a POST request with a JSON body and an Authorization header.
func e2ePostAuth(t *testing.T, srv *httptest.Server, path, body, authHeader string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("e2ePostAuth: NewRequest: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("e2ePostAuth: Do: %v", err)
	}
	return resp
}

// readBody reads and closes the response body, returning the raw bytes.
func readBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("readBody: %v", err)
	}
	return b
}

// e2eSignup signs up a unique user and returns their user_id and Bearer token.
// The caller is responsible for registering cleanup.
func e2eSignup(t *testing.T, srv *httptest.Server, base string) (userID, token string) {
	t.Helper()
	username := e2eUniqueUsername(base)
	password := "E2etestpass1"
	reqBody := fmt.Sprintf(`{"username":%q,"password":%q}`, username, password)

	resp := e2ePost(t, srv, "/auth/signup", reqBody)
	if resp.StatusCode != http.StatusCreated {
		b := readBody(t, resp)
		t.Fatalf("e2eSignup: want 201, got %d: %s", resp.StatusCode, b)
	}

	var out struct {
		UserID string `json:"user_id"`
		Token  string `json:"token"`
	}
	decodeJSON(t, resp, &out)
	return out.UserID, out.Token
}

// e2eCleanupGameplay deletes, in FK order, all gameplay rows for a user plus the
// user itself. Register via t.Cleanup so it runs even on test failure.
func e2eCleanupGameplay(t *testing.T, pool *pgxpool.Pool, userID string) {
	t.Helper()
	id, err := uuid.Parse(userID)
	if err != nil {
		t.Logf("e2eCleanupGameplay: bad uuid %q: %v", userID, err)
		return
	}
	ctx := context.Background()
	// FK order: match_summary → record → match → profile → user_login.
	pool.Exec(ctx, //nolint:errcheck
		`DELETE FROM match_summary WHERE match_id IN (SELECT match_id FROM match WHERE user_id = $1)`, id)
	pool.Exec(ctx, //nolint:errcheck
		`DELETE FROM record WHERE match_id IN (SELECT match_id FROM match WHERE user_id = $1)`, id)
	pool.Exec(ctx, `DELETE FROM match WHERE user_id = $1`, id)      //nolint:errcheck
	pool.Exec(ctx, `DELETE FROM profile WHERE user_id = $1`, id)    //nolint:errcheck
	pool.Exec(ctx, `DELETE FROM user_login WHERE user_id = $1`, id) //nolint:errcheck
}

// countRecords returns the number of record rows for a given match_id in the DB.
func countRecords(t *testing.T, pool *pgxpool.Pool, matchID string) int {
	t.Helper()
	mid, err := uuid.Parse(matchID)
	if err != nil {
		t.Fatalf("countRecords: parse matchID %q: %v", matchID, err)
	}
	var n int
	err = pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM record WHERE match_id = $1`, mid).Scan(&n)
	if err != nil {
		t.Fatalf("countRecords: query: %v", err)
	}
	return n
}

// ── tests ─────────────────────────────────────────────────────────────────────

// TestGameplayE2E_FullFlow exercises the complete happy-path gameplay CRUD
// sequence for a single user:
//   - POST /matches 201, body contains match_id, ended_at null, court_surface echoed
//   - GET /matches/{id} 200
//   - GET /matches 200, list contains the new match
//   - Single add (one-element shots) → 201; N-element batch → 201; GET /records = N+1 total
//   - GET /matches/{id}/summary before end → []
//   - POST /matches/{id}/end → 200 with non-null ended_at
//   - GET /matches/{id}/summary → per-zone counts match shots added
//   - POST /matches/{id}/end again → 409 (OQ-2)
//   - POST /matches/{id}/records on ended match (valid body) → 409 (OQ-3)
func TestGameplayE2E_FullFlow(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userID, token := e2eSignup(t, srv, "gplay_a")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userID) })
	bearer := "Bearer " + token

	// ── create match ──────────────────────────────────────────────────────────
	createResp := e2ePostAuth(t, srv, "/matches",
		`{"court_surface":"clay"}`, bearer)
	if createResp.StatusCode != http.StatusCreated {
		b := readBody(t, createResp)
		t.Fatalf("POST /matches: want 201, got %d: %s", createResp.StatusCode, b)
	}

	var createBody struct {
		MatchID      string      `json:"match_id"`
		CourtSurface string      `json:"court_surface"`
		EndedAt      interface{} `json:"ended_at"`
	}
	decodeJSON(t, createResp, &createBody)

	if createBody.MatchID == "" {
		t.Fatal("POST /matches: match_id is empty")
	}
	if createBody.CourtSurface != "clay" {
		t.Errorf("POST /matches: court_surface = %q, want %q", createBody.CourtSurface, "clay")
	}
	if createBody.EndedAt != nil {
		t.Errorf("POST /matches: ended_at want null, got %v", createBody.EndedAt)
	}
	matchID := createBody.MatchID

	// ── GET /matches/{id} ─────────────────────────────────────────────────────
	getResp := e2eGet(t, srv, "/matches/"+matchID, bearer)
	if getResp.StatusCode != http.StatusOK {
		b := readBody(t, getResp)
		t.Fatalf("GET /matches/%s: want 200, got %d: %s", matchID, getResp.StatusCode, b)
	}
	var getBody struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, getResp, &getBody)
	if getBody.MatchID != matchID {
		t.Errorf("GET /matches/{id}: match_id = %q, want %q", getBody.MatchID, matchID)
	}

	// ── GET /matches (list) ───────────────────────────────────────────────────
	listResp := e2eGet(t, srv, "/matches", bearer)
	if listResp.StatusCode != http.StatusOK {
		b := readBody(t, listResp)
		t.Fatalf("GET /matches: want 200, got %d: %s", listResp.StatusCode, b)
	}
	var listBody []struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, listResp, &listBody)
	found := false
	for _, m := range listBody {
		if m.MatchID == matchID {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("GET /matches: created match %s not found in list", matchID)
	}

	// ── single add (one shot, ts_ms=40 — intentionally HIGH so the batch below
	//    can provide lower ts_ms values, proving the handler honours ORDER BY
	//    ts_ms ASC rather than returning insertion order) ──────────────────────
	addOneResp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records",
		`{"shots":[{"zone":"baseline","ts_ms":40}]}`, bearer)
	if addOneResp.StatusCode != http.StatusCreated {
		b := readBody(t, addOneResp)
		t.Fatalf("POST /matches/%s/records (single): want 201, got %d: %s", matchID, addOneResp.StatusCode, b)
	}
	var addOneBody struct {
		Created   int      `json:"created"`
		RecordIDs []string `json:"record_ids"`
	}
	decodeJSON(t, addOneResp, &addOneBody)
	if addOneBody.Created != 1 {
		t.Errorf("add single: created = %d, want 1", addOneBody.Created)
	}
	if len(addOneBody.RecordIDs) != 1 {
		t.Errorf("add single: len(record_ids) = %d, want 1", len(addOneBody.RecordIDs))
	}

	// ── N-element batch add (3 shots with ts_ms lower than the single shot
	//    inserted above: 10, 20, 30 — insertion order would place the single
	//    shot first, but ORDER BY ts_ms ASC must surface these three first) ────
	addBatchResp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records",
		`{"shots":[{"zone":"baseline","ts_ms":10},{"zone":"net","ts_ms":20},{"zone":"net","ts_ms":30}]}`, bearer)
	if addBatchResp.StatusCode != http.StatusCreated {
		b := readBody(t, addBatchResp)
		t.Fatalf("POST /matches/%s/records (batch): want 201, got %d: %s", matchID, addBatchResp.StatusCode, b)
	}
	var addBatchBody struct {
		Created int `json:"created"`
	}
	decodeJSON(t, addBatchResp, &addBatchBody)
	if addBatchBody.Created != 3 {
		t.Errorf("add batch: created = %d, want 3", addBatchBody.Created)
	}

	// ── GET /records — expect 4 total (1+3).
	// Expected ORDER BY ts_ms ASC: 10, 20, 30, 40.
	// Insertion order was: 40 (single), then 10/20/30 (batch) — so if the
	// handler returned insertion order the sequence would be 40,10,20,30 and
	// the assertion below would fail, proving the sort is actually applied.
	recResp := e2eGet(t, srv, "/matches/"+matchID+"/records", bearer)
	if recResp.StatusCode != http.StatusOK {
		b := readBody(t, recResp)
		t.Fatalf("GET /matches/%s/records: want 200, got %d: %s", matchID, recResp.StatusCode, b)
	}
	var recList []struct {
		Zone string `json:"zone"`
		TsMs *int32 `json:"ts_ms"`
	}
	decodeJSON(t, recResp, &recList)
	if len(recList) != 4 {
		t.Errorf("GET /records: want 4 records, got %d", len(recList))
	}
	// Verify deterministic ORDER BY ts_ms ASC: 10, 20, 30, 40.
	if len(recList) == 4 {
		expectedTsMs := []int32{10, 20, 30, 40}
		for i, r := range recList {
			if r.TsMs == nil {
				t.Errorf("GET /records[%d]: ts_ms is nil, want %d", i, expectedTsMs[i])
				continue
			}
			if *r.TsMs != expectedTsMs[i] {
				t.Errorf("GET /records[%d]: ts_ms = %d, want %d", i, *r.TsMs, expectedTsMs[i])
			}
		}
	}

	// ── summary BEFORE end → [] (AC20 / OQ-1) ────────────────────────────────
	summaryBeforeResp := e2eGet(t, srv, "/matches/"+matchID+"/summary", bearer)
	if summaryBeforeResp.StatusCode != http.StatusOK {
		b := readBody(t, summaryBeforeResp)
		t.Fatalf("GET /matches/%s/summary (before end): want 200, got %d: %s", matchID, summaryBeforeResp.StatusCode, b)
	}
	summaryBeforeBytes := readBody(t, summaryBeforeResp)
	var summaryBeforeArr []interface{}
	if err := json.Unmarshal(summaryBeforeBytes, &summaryBeforeArr); err != nil {
		t.Fatalf("summary before end: decode: %v", err)
	}
	if len(summaryBeforeArr) != 0 {
		t.Errorf("summary before end: want [], got %d elements", len(summaryBeforeArr))
	}

	// ── POST /matches/{id}/end → 200, ended_at non-null ───────────────────────
	endResp := e2ePostAuth(t, srv, "/matches/"+matchID+"/end", "", bearer)
	if endResp.StatusCode != http.StatusOK {
		b := readBody(t, endResp)
		t.Fatalf("POST /matches/%s/end: want 200, got %d: %s", matchID, endResp.StatusCode, b)
	}
	var endBody struct {
		EndedAt *time.Time `json:"ended_at"`
	}
	decodeJSON(t, endResp, &endBody)
	if endBody.EndedAt == nil {
		t.Error("POST /end: ended_at is null, want non-null")
	}

	// ── GET /summary after end → per-zone counts ──────────────────────────────
	// shots: baseline×2, net×2 → expect 2 summary rows.
	summaryResp := e2eGet(t, srv, "/matches/"+matchID+"/summary", bearer)
	if summaryResp.StatusCode != http.StatusOK {
		b := readBody(t, summaryResp)
		t.Fatalf("GET /matches/%s/summary (after end): want 200, got %d: %s", matchID, summaryResp.StatusCode, b)
	}
	var summaryRows []struct {
		Zone      string `json:"zone"`
		ShotCount int    `json:"shot_count"`
	}
	decodeJSON(t, summaryResp, &summaryRows)
	if len(summaryRows) != 2 {
		t.Errorf("summary after end: want 2 zones, got %d", len(summaryRows))
	}
	zoneCounts := make(map[string]int, len(summaryRows))
	for _, sr := range summaryRows {
		zoneCounts[sr.Zone] = sr.ShotCount
	}
	if zoneCounts["baseline"] != 2 {
		t.Errorf("summary zone baseline: want 2, got %d", zoneCounts["baseline"])
	}
	if zoneCounts["net"] != 2 {
		t.Errorf("summary zone net: want 2, got %d", zoneCounts["net"])
	}

	// ── double-end → 409 (OQ-2) ───────────────────────────────────────────────
	end2Resp := e2ePostAuth(t, srv, "/matches/"+matchID+"/end", "", bearer)
	if end2Resp.StatusCode != http.StatusConflict {
		b := readBody(t, end2Resp)
		t.Errorf("POST /end (again): want 409, got %d: %s", end2Resp.StatusCode, b)
	} else {
		var end2Body map[string]string
		if err := json.NewDecoder(end2Resp.Body).Decode(&end2Body); err == nil {
			if end2Body["error"] != "match already ended" {
				t.Errorf("POST /end (again): error = %q, want %q", end2Body["error"], "match already ended")
			}
		}
		_ = end2Resp.Body.Close()
	}

	// ── records on ended match (valid body) → 409 (OQ-3) ─────────────────────
	recEndedResp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records",
		`{"shots":[{"zone":"baseline"}]}`, bearer)
	if recEndedResp.StatusCode != http.StatusConflict {
		b := readBody(t, recEndedResp)
		t.Errorf("POST /records on ended match: want 409, got %d: %s", recEndedResp.StatusCode, b)
	} else {
		_ = recEndedResp.Body.Close()
	}
}

// TestGameplayE2E_BadSurface verifies AC9: POST /matches with an invalid
// court_surface returns 400 and no match row is created.
func TestGameplayE2E_BadSurface(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userID, token := e2eSignup(t, srv, "gplay_bad_surf")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userID) })
	bearer := "Bearer " + token

	resp := e2ePostAuth(t, srv, "/matches",
		`{"court_surface":"carpet"}`, bearer)
	if resp.StatusCode != http.StatusBadRequest {
		b := readBody(t, resp)
		t.Errorf("bad surface: want 400, got %d: %s", resp.StatusCode, b)
	} else {
		_ = resp.Body.Close()
	}

	// Confirm no match row was created.
	uid, _ := uuid.Parse(userID)
	var count int
	err := pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM match WHERE user_id = $1`, uid).Scan(&count)
	if err != nil {
		t.Fatalf("bad surface: count query: %v", err)
	}
	if count != 0 {
		t.Errorf("bad surface: want 0 match rows, found %d", count)
	}
}

// TestGameplayE2E_BadBatch verifies AC15: each of the bad batch shapes returns
// 400 and inserts zero record rows.
func TestGameplayE2E_BadBatch(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userID, token := e2eSignup(t, srv, "gplay_bad_batch")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userID) })
	bearer := "Bearer " + token

	// Create a valid match first.
	createResp := e2ePostAuth(t, srv, "/matches",
		`{"court_surface":"hard"}`, bearer)
	if createResp.StatusCode != http.StatusCreated {
		b := readBody(t, createResp)
		t.Fatalf("bad batch setup: want 201, got %d: %s", createResp.StatusCode, b)
	}
	var createBody struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, createResp, &createBody)
	matchID := createBody.MatchID

	badCases := []struct {
		name string
		body string
	}{
		{"empty shots array", `{"shots":[]}`},
		{"shot with empty zone", `{"shots":[{"zone":""}]}`},
		{"shot with bad source", `{"shots":[{"zone":"baseline","source":"bogus"}]}`},
	}

	for _, tc := range badCases {
		tc := tc // capture
		t.Run(tc.name, func(t *testing.T) {
			before := countRecords(t, pool, matchID)

			resp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records", tc.body, bearer)
			if resp.StatusCode != http.StatusBadRequest {
				b := readBody(t, resp)
				t.Errorf("%s: want 400, got %d: %s", tc.name, resp.StatusCode, b)
			} else {
				_ = resp.Body.Close()
			}

			after := countRecords(t, pool, matchID)
			if after != before {
				t.Errorf("%s: record count changed from %d to %d (want no insertion)", tc.name, before, after)
			}
		})
	}
}

// TestGameplayE2E_OwnershipParity verifies AC-Z1: as user B, every {id} route
// for user A's match returns a byte-identical 404 body matching a random
// nonexistent UUID. No 403, no existence leak.
//
// Also verifies AC-Z2: after B's failed mutations, A's match is unchanged and
// no stray record rows exist from B's attempts.
func TestGameplayE2E_OwnershipParity(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userAID, tokenA := e2eSignup(t, srv, "gplay_owner_a")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userAID) })
	bearerA := "Bearer " + tokenA

	userBID, tokenB := e2eSignup(t, srv, "gplay_owner_b")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userBID) })
	bearerB := "Bearer " + tokenB

	// A creates a match and adds one record.
	createResp := e2ePostAuth(t, srv, "/matches",
		`{"court_surface":"grass"}`, bearerA)
	if createResp.StatusCode != http.StatusCreated {
		b := readBody(t, createResp)
		t.Fatalf("ownership parity setup: want 201, got %d: %s", createResp.StatusCode, b)
	}
	var createBody struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, createResp, &createBody)
	matchID := createBody.MatchID

	addResp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records",
		`{"shots":[{"zone":"baseline","ts_ms":1}]}`, bearerA)
	if addResp.StatusCode != http.StatusCreated {
		b := readBody(t, addResp)
		t.Fatalf("ownership parity setup add records: want 201, got %d: %s", addResp.StatusCode, b)
	}
	_ = addResp.Body.Close()

	// Establish baseline: A can GET the match; match is not ended.
	getAResp := e2eGet(t, srv, "/matches/"+matchID, bearerA)
	if getAResp.StatusCode != http.StatusOK {
		b := readBody(t, getAResp)
		t.Fatalf("ownership parity: A GET own match: want 200, got %d: %s", getAResp.StatusCode, b)
	}
	var getABody struct {
		EndedAt interface{} `json:"ended_at"`
	}
	decodeJSON(t, getAResp, &getABody)
	if getABody.EndedAt != nil {
		t.Fatal("ownership parity setup: ended_at should be null before any end")
	}

	// Get the reference body from a random nonexistent UUID (as user B).
	randomID := uuid.New().String()
	refGetBytes := readBody(t, e2eGet(t, srv, "/matches/"+randomID, bearerB))

	// Decode and sanity-check the reference.
	var refErr map[string]string
	if err := json.Unmarshal(refGetBytes, &refErr); err != nil {
		t.Fatalf("ownership parity: reference 404 body not JSON: %s", refGetBytes)
	}
	if refErr["error"] != "match not found" {
		t.Errorf("ownership parity: reference 404 error = %q, want %q", refErr["error"], "match not found")
	}

	t.Run("GET /matches/{id}", func(t *testing.T) {
		resp := e2eGet(t, srv, "/matches/"+matchID, bearerB)
		if resp.StatusCode != http.StatusNotFound {
			b := readBody(t, resp)
			t.Errorf("B GET A match: want 404, got %d: %s", resp.StatusCode, b)
			return
		}
		got := readBody(t, resp)
		if !bytes.Equal(got, refGetBytes) {
			t.Errorf("B GET A match: body not byte-identical to nonexistent id\n  got: %s\n want: %s", got, refGetBytes)
		}
	})

	t.Run("POST /matches/{id}/end", func(t *testing.T) {
		resp := e2ePostAuth(t, srv, "/matches/"+matchID+"/end", "", bearerB)
		if resp.StatusCode != http.StatusNotFound {
			b := readBody(t, resp)
			t.Errorf("B end A match: want 404, got %d: %s", resp.StatusCode, b)
			return
		}
		got := readBody(t, resp)
		refEndBytes := readBody(t, e2ePostAuth(t, srv, "/matches/"+randomID+"/end", "", bearerB))
		if !bytes.Equal(got, refEndBytes) {
			t.Errorf("B end A match: body not byte-identical to nonexistent id\n  got: %s\n want: %s", got, refEndBytes)
		}
	})

	t.Run("POST /matches/{id}/records", func(t *testing.T) {
		// Must send a valid body so validation passes and ownership check is reached.
		resp := e2ePostAuth(t, srv, "/matches/"+matchID+"/records",
			`{"shots":[{"zone":"net"}]}`, bearerB)
		if resp.StatusCode != http.StatusNotFound {
			b := readBody(t, resp)
			t.Errorf("B add to A match: want 404, got %d: %s", resp.StatusCode, b)
			return
		}
		got := readBody(t, resp)
		refRecBytes := readBody(t, e2ePostAuth(t, srv, "/matches/"+randomID+"/records",
			`{"shots":[{"zone":"net"}]}`, bearerB))
		if !bytes.Equal(got, refRecBytes) {
			t.Errorf("B add to A match: body not byte-identical to nonexistent id\n  got: %s\n want: %s", got, refRecBytes)
		}
	})

	t.Run("GET /matches/{id}/records", func(t *testing.T) {
		resp := e2eGet(t, srv, "/matches/"+matchID+"/records", bearerB)
		if resp.StatusCode != http.StatusNotFound {
			b := readBody(t, resp)
			t.Errorf("B list A records: want 404, got %d: %s", resp.StatusCode, b)
			return
		}
		got := readBody(t, resp)
		refRecListBytes := readBody(t, e2eGet(t, srv, "/matches/"+randomID+"/records", bearerB))
		if !bytes.Equal(got, refRecListBytes) {
			t.Errorf("B list A records: body not byte-identical\n  got: %s\n want: %s", got, refRecListBytes)
		}
	})

	t.Run("GET /matches/{id}/summary", func(t *testing.T) {
		resp := e2eGet(t, srv, "/matches/"+matchID+"/summary", bearerB)
		if resp.StatusCode != http.StatusNotFound {
			b := readBody(t, resp)
			t.Errorf("B get A summary: want 404, got %d: %s", resp.StatusCode, b)
			return
		}
		got := readBody(t, resp)
		refSummaryBytes := readBody(t, e2eGet(t, srv, "/matches/"+randomID+"/summary", bearerB))
		if !bytes.Equal(got, refSummaryBytes) {
			t.Errorf("B get A summary: body not byte-identical\n  got: %s\n want: %s", got, refSummaryBytes)
		}
	})

	// ── AC-Z2: A's match unchanged after B's failed mutations ─────────────────
	getAfterResp := e2eGet(t, srv, "/matches/"+matchID, bearerA)
	if getAfterResp.StatusCode != http.StatusOK {
		b := readBody(t, getAfterResp)
		t.Fatalf("AC-Z2: A GET match after B attacks: want 200, got %d: %s", getAfterResp.StatusCode, b)
	}
	var getAfterBody struct {
		EndedAt interface{} `json:"ended_at"`
	}
	decodeJSON(t, getAfterResp, &getAfterBody)
	if getAfterBody.EndedAt != nil {
		t.Error("AC-Z2: A's match ended_at changed after B's failed end attempt")
	}

	recordCountAfter := countRecords(t, pool, matchID)
	if recordCountAfter != 1 {
		t.Errorf("AC-Z2: A's record count = %d after B's failed add, want 1", recordCountAfter)
	}
}

// TestGameplayE2E_AuthBeforeOwnership verifies AC-Z3: requests to gameplay
// routes with a missing or invalid token receive 401 — the auth middleware fires
// before any match lookup, so no ownership info is leaked.
func TestGameplayE2E_AuthBeforeOwnership(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	// Create a match under a real user so there IS a real id to probe.
	userID, token := e2eSignup(t, srv, "gplay_auth_before")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userID) })
	bearer := "Bearer " + token

	createResp := e2ePostAuth(t, srv, "/matches",
		`{"court_surface":"hard"}`, bearer)
	if createResp.StatusCode != http.StatusCreated {
		b := readBody(t, createResp)
		t.Fatalf("auth-before-ownership setup: want 201, got %d: %s", createResp.StatusCode, b)
	}
	var createBody struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, createResp, &createBody)
	matchID := createBody.MatchID

	invalidToken := "Bearer invalid.token.here"

	authCases := []struct {
		name        string
		method      string
		path        string
		body        string
		authHeader  string
	}{
		{"no token GET match", "GET", "/matches/" + matchID, "", ""},
		{"invalid token GET match", "GET", "/matches/" + matchID, "", invalidToken},
		{"no token POST end", "POST", "/matches/" + matchID + "/end", "", ""},
		{"invalid token POST end", "POST", "/matches/" + matchID + "/end", "", invalidToken},
		{"no token POST records", "POST", "/matches/" + matchID + "/records", `{"shots":[{"zone":"net"}]}`, ""},
		{"invalid token POST records", "POST", "/matches/" + matchID + "/records", `{"shots":[{"zone":"net"}]}`, invalidToken},
		{"no token GET records", "GET", "/matches/" + matchID + "/records", "", ""},
		{"no token GET summary", "GET", "/matches/" + matchID + "/summary", "", ""},
	}

	for _, tc := range authCases {
		tc := tc // capture
		t.Run(tc.name, func(t *testing.T) {
			var reqBody io.Reader
			if tc.body != "" {
				reqBody = strings.NewReader(tc.body)
			}
			req, err := http.NewRequest(tc.method, srv.URL+tc.path, reqBody)
			if err != nil {
				t.Fatalf("%s: NewRequest: %v", tc.name, err)
			}
			if tc.body != "" {
				req.Header.Set("Content-Type", "application/json")
			}
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("%s: Do: %v", tc.name, err)
			}
			defer func() { _ = resp.Body.Close() }()

			if resp.StatusCode != http.StatusUnauthorized {
				t.Errorf("%s: want 401, got %d", tc.name, resp.StatusCode)
			}
		})
	}
}

// TestGameplayE2E_UnparseableID verifies that a non-UUID {id} (e.g. "not-a-uuid")
// returns 404 {"error":"match not found"} — indistinguishable from a real miss.
func TestGameplayE2E_UnparseableID(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userID, token := e2eSignup(t, srv, "gplay_bad_id")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userID) })
	bearer := "Bearer " + token

	bogusID := "not-a-uuid"

	routes := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{"GET /matches/{id}", "GET", "/matches/" + bogusID, ""},
		{"POST /matches/{id}/end", "POST", "/matches/" + bogusID + "/end", ""},
		{"POST /matches/{id}/records", "POST", "/matches/" + bogusID + "/records", `{"shots":[{"zone":"baseline"}]}`},
		{"GET /matches/{id}/records", "GET", "/matches/" + bogusID + "/records", ""},
		{"GET /matches/{id}/summary", "GET", "/matches/" + bogusID + "/summary", ""},
	}

	for _, tc := range routes {
		tc := tc // capture
		t.Run(tc.name, func(t *testing.T) {
			var resp *http.Response
			if tc.method == "GET" {
				resp = e2eGet(t, srv, tc.path, bearer)
			} else {
				resp = e2ePostAuth(t, srv, tc.path, tc.body, bearer)
			}
			b := readBody(t, resp)
			if resp.StatusCode != http.StatusNotFound {
				t.Errorf("%s bogus id: want 404, got %d: %s", tc.name, resp.StatusCode, b)
				return
			}
			var errBody map[string]string
			if err := json.Unmarshal(b, &errBody); err != nil {
				t.Fatalf("%s bogus id: body not JSON: %s", tc.name, b)
			}
			if errBody["error"] != "match not found" {
				t.Errorf("%s bogus id: error = %q, want %q", tc.name, errBody["error"], "match not found")
			}
		})
	}
}

// TestGameplayE2E_ListIsolation verifies AC10: user A and user B each create a
// match; GET /matches for each user returns only their own match.
func TestGameplayE2E_ListIsolation(t *testing.T) {
	srv, pool := e2eBuildServer(t, testSigningKey)

	userAID, tokenA := e2eSignup(t, srv, "gplay_list_a")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userAID) })
	bearerA := "Bearer " + tokenA

	userBID, tokenB := e2eSignup(t, srv, "gplay_list_b")
	t.Cleanup(func() { e2eCleanupGameplay(t, pool, userBID) })
	bearerB := "Bearer " + tokenB

	// A creates match.
	respA := e2ePostAuth(t, srv, "/matches", `{"court_surface":"hard"}`, bearerA)
	if respA.StatusCode != http.StatusCreated {
		b := readBody(t, respA)
		t.Fatalf("list isolation: A create: want 201, got %d: %s", respA.StatusCode, b)
	}
	var aMatch struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, respA, &aMatch)

	// B creates match.
	respB := e2ePostAuth(t, srv, "/matches", `{"court_surface":"clay"}`, bearerB)
	if respB.StatusCode != http.StatusCreated {
		b := readBody(t, respB)
		t.Fatalf("list isolation: B create: want 201, got %d: %s", respB.StatusCode, b)
	}
	var bMatch struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, respB, &bMatch)

	// A's list: must contain A's match, must NOT contain B's match.
	listAResp := e2eGet(t, srv, "/matches", bearerA)
	if listAResp.StatusCode != http.StatusOK {
		b := readBody(t, listAResp)
		t.Fatalf("list isolation: A list: want 200, got %d: %s", listAResp.StatusCode, b)
	}
	var aList []struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, listAResp, &aList)
	aHasOwn, aHasB := false, false
	for _, m := range aList {
		if m.MatchID == aMatch.MatchID {
			aHasOwn = true
		}
		if m.MatchID == bMatch.MatchID {
			aHasB = true
		}
	}
	if !aHasOwn {
		t.Error("list isolation: A's list missing A's own match")
	}
	if aHasB {
		t.Error("list isolation: A's list contains B's match (isolation failure)")
	}

	// B's list: must contain B's match, must NOT contain A's match.
	listBResp := e2eGet(t, srv, "/matches", bearerB)
	if listBResp.StatusCode != http.StatusOK {
		b := readBody(t, listBResp)
		t.Fatalf("list isolation: B list: want 200, got %d: %s", listBResp.StatusCode, b)
	}
	var bList []struct {
		MatchID string `json:"match_id"`
	}
	decodeJSON(t, listBResp, &bList)
	bHasOwn, bHasA := false, false
	for _, m := range bList {
		if m.MatchID == bMatch.MatchID {
			bHasOwn = true
		}
		if m.MatchID == aMatch.MatchID {
			bHasA = true
		}
	}
	if !bHasOwn {
		t.Error("list isolation: B's list missing B's own match")
	}
	if bHasA {
		t.Error("list isolation: B's list contains A's match (isolation failure)")
	}
}

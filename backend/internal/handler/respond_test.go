package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestWriteError(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		msg        string
		wantStatus int
		wantBody   string
		wantCT     string
	}{
		{
			name:       "409 username already taken",
			status:     http.StatusConflict,
			msg:        "username already taken",
			wantStatus: 409,
			wantBody:   `{"error":"username already taken"}`,
			wantCT:     "application/json",
		},
		{
			name:       "400 bad request",
			status:     http.StatusBadRequest,
			msg:        "bad request",
			wantStatus: 400,
			wantBody:   `{"error":"bad request"}`,
			wantCT:     "application/json",
		},
		{
			name:       "401 unauthorized",
			status:     http.StatusUnauthorized,
			msg:        "unauthorized",
			wantStatus: 401,
			wantBody:   `{"error":"unauthorized"}`,
			wantCT:     "application/json",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			writeError(rec, tt.status, tt.msg)

			if rec.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantStatus)
			}

			got := rec.Body.String()
			if got != tt.wantBody {
				t.Errorf("body = %q, want %q", got, tt.wantBody)
			}

			ct := rec.Header().Get("Content-Type")
			if ct != tt.wantCT {
				t.Errorf("Content-Type = %q, want %q", ct, tt.wantCT)
			}
		})
	}
}

func TestWriteJSON(t *testing.T) {
	type sample struct {
		Name  string `json:"name"`
		Count int    `json:"count"`
	}

	tests := []struct {
		name       string
		status     int
		payload    any
		wantStatus int
		wantBody   string
		wantCT     string
	}{
		{
			name:       "200 with struct",
			status:     http.StatusOK,
			payload:    sample{Name: "ace", Count: 3},
			wantStatus: 200,
			wantBody:   `{"name":"ace","count":3}`,
			wantCT:     "application/json",
		},
		{
			name:       "201 created with struct",
			status:     http.StatusCreated,
			payload:    sample{Name: "rally", Count: 1},
			wantStatus: 201,
			wantBody:   `{"name":"rally","count":1}`,
			wantCT:     "application/json",
		},
		{
			name:       "204 no content with nil struct",
			status:     http.StatusNoContent,
			payload:    struct{}{},
			wantStatus: 204,
			wantBody:   `{}`,
			wantCT:     "application/json",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			writeJSON(rec, tt.status, tt.payload)

			if rec.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantStatus)
			}

			got := rec.Body.String()
			if got != tt.wantBody {
				t.Errorf("body = %q, want %q", got, tt.wantBody)
			}

			ct := rec.Header().Get("Content-Type")
			if ct != tt.wantCT {
				t.Errorf("Content-Type = %q, want %q", ct, tt.wantCT)
			}
		})
	}
}

// TestWriteJSON_MarshalFailure exercises the error branch (lines 14-17 of respond.go):
// when json.Marshal fails (e.g. a channel), writeJSON falls through to http.Error,
// which returns 500, text/plain content-type, and appends a trailing newline.
func TestWriteJSON_MarshalFailure(t *testing.T) {
	rec := httptest.NewRecorder()
	writeJSON(rec, http.StatusOK, make(chan int)) // chan is not JSON-serialisable

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", rec.Code)
	}

	wantBody := `{"error":"internal server error"}` + "\n"
	got := rec.Body.String()
	if got != wantBody {
		t.Errorf("body = %q, want %q", got, wantBody)
	}

	// http.Error sets text/plain; charset=utf-8, not application/json
	ct := rec.Header().Get("Content-Type")
	wantCT := "text/plain; charset=utf-8"
	if ct != wantCT {
		t.Errorf("Content-Type = %q, want %q", ct, wantCT)
	}
}

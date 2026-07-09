package handler

import "net/http"

// Health handles GET /health.
// It returns 200 {"status":"ok"} as a pure liveness check — no DB probe (OQ-3).
func Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, struct {
		Status string `json:"status"`
	}{Status: "ok"})
}

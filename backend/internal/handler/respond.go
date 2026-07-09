package handler

import (
	"encoding/json"
	"net/http"
)

// writeJSON marshals v, sets Content-Type: application/json, writes the given
// HTTP status code, and writes the marshalled bytes. Marshalling before headers
// ensures Content-Type is always set even when v cannot be marshalled (in which
// case a 500 is returned instead).
func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(b) //nolint:errcheck // write errors on ResponseWriter are not actionable
}

// writeError writes exactly {"error":"<msg>"} with the given status code.
func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, struct {
		Error string `json:"error"`
	}{Error: msg})
}

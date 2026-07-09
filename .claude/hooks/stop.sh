#!/bin/bash
# .claude/hooks/stop.sh
# Stop hook — fires when an agent session is about to end.
# Verifies minimum completion criteria.
# Exit 0 = allow stop, Exit 2 = force agent to continue.
# Skips checks gracefully if the project layer doesn't exist yet.

set -euo pipefail

# ──────────────────────────────────────────────
# Check: uncommitted changes?
# ──────────────────────────────────────────────
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "⚠️ Uncommitted changes detected. Commit or stash before stopping." >&2
  git status --short >&2
  exit 2
fi

# ──────────────────────────────────────────────
# Check: Go backend compiles and tests pass?
# Skip if backend/ doesn't exist yet (pre-Phase 1).
# ──────────────────────────────────────────────
if [[ -d backend/ ]] && [[ -f backend/go.mod ]]; then
  echo "Checking Go backend..." >&2
  if ! (cd backend/ && go build ./... 2>/dev/null); then
    echo "⚠️ Go build failed. Fix before stopping." >&2
    exit 2
  fi
  if ! (cd backend/ && go test ./... 2>/dev/null); then
    echo "⚠️ Go tests failing. Fix before stopping." >&2
    exit 2
  fi
else
  echo "(skip: backend/ not yet created)" >&2
fi

# ──────────────────────────────────────────────
# Check: Python CV pipeline type-checks?
# Skip if cv/ doesn't exist yet.
# ──────────────────────────────────────────────
if [[ -d cv/ ]] && [[ -f cv/requirements.txt ]]; then
  echo "Checking Python CV pipeline..." >&2
  if command -v mypy &>/dev/null; then
    if ! (cd cv/ && python -m mypy pipeline/ --strict 2>/dev/null); then
      echo "⚠️ mypy errors in cv/pipeline/. Fix before stopping." >&2
      exit 2
    fi
  else
    echo "(skip: mypy not installed)" >&2
  fi
else
  echo "(skip: cv/ not yet created)" >&2
fi

echo "✅ Stop checks passed."
exit 0

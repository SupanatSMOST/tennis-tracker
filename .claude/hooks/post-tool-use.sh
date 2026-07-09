#!/bin/bash
# .claude/hooks/post-tool-use.sh
# PostToolUse hook — fires after tool execution.
# Validates code quality after writes/edits.
# Exit 0 = OK, Exit 1 = warn (non-blocking), Exit 2 = block.

set -euo pipefail

TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# ──────────────────────────────────────────────
# After file writes: run formatter on changed file
# ──────────────────────────────────────────────
if [[ "$TOOL_NAME" =~ ^(Write|Edit)$ ]]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('file_path',''))" 2>/dev/null || true)

  if [[ -n "$FILE_PATH" ]]; then
    # Go: auto-format
    if [[ "$FILE_PATH" =~ \.go$ ]] && command -v gofmt &>/dev/null; then
      gofmt -w "$FILE_PATH" 2>/dev/null || true
    fi

    # Python: auto-format
    if [[ "$FILE_PATH" =~ \.py$ ]] && command -v ruff &>/dev/null; then
      ruff format "$FILE_PATH" 2>/dev/null || true
    fi

    # Swift: auto-format (swiftformat if available)
    if [[ "$FILE_PATH" =~ \.swift$ ]] && command -v swiftformat &>/dev/null; then
      swiftformat "$FILE_PATH" 2>/dev/null || true
    fi
  fi
fi

# ──────────────────────────────────────────────
# After git commit: scan for secrets
# ──────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Bash" ]]; then
  if echo "$TOOL_INPUT" | grep -q "git commit"; then
    LAST_DIFF=$(git diff HEAD~1 HEAD --no-color 2>/dev/null || true)
    if echo "$LAST_DIFF" | grep -iEq "(api[_-]?key|secret|password|token)=['\"][^'\"]{8,}"; then
      echo "❌ BLOCKED: Potential secret in commit. Amend and remove it." >&2
      exit 2
    fi
  fi
fi

exit 0

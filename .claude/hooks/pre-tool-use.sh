#!/bin/bash
# .claude/hooks/pre-tool-use.sh
# PreToolUse hook — fires before any tool execution.
# Exit 0 = allow, Exit 2 = BLOCK (hard deny), Exit 1 = warn only.

set -euo pipefail

TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# ──────────────────────────────────────────────
# BLOCK: Protected paths
# ──────────────────────────────────────────────
if [[ "$TOOL_NAME" =~ ^(Write|Edit)$ ]]; then
  PROTECTED_PATTERNS=(
    ".env"
    "managed-settings.json"
    ".claude/hooks/"
  )

  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if echo "$TOOL_INPUT" | grep -q "$pattern"; then
      echo "❌ BLOCKED: Cannot modify protected path matching '$pattern'" >&2
      exit 2
    fi
  done
fi

# ──────────────────────────────────────────────
# BLOCK: Dangerous bash commands
# ──────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Bash" ]]; then
  DANGEROUS_PATTERNS=(
    "rm -rf /"
    "rm -rf ~"
    "gh pr merge"
    "git push.*--force.*main"
    "git push origin main"
    "curl.*| sh"
    "curl.*| bash"
    "wget.*| sh"
    "wget.*| bash"
    "/proc/self/environ"
    "cat /etc/shadow"
  )

  for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if echo "$TOOL_INPUT" | grep -qE "$pattern"; then
      echo "❌ BLOCKED: Dangerous pattern '$pattern'" >&2
      exit 2
    fi
  done

  # Block auto-merge
  if echo "$TOOL_INPUT" | grep -qE "gh pr merge.*--auto"; then
    echo "❌ BLOCKED: Auto-merge is not allowed" >&2
    exit 2
  fi
fi

# ──────────────────────────────────────────────
# BLOCK: Sensitive file reads
# ──────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Read" ]]; then
  SENSITIVE_PATTERNS=(
    ".env"
    ".env.local"
    ".env.production"
    "id_rsa"
    "id_ed25519"
    ".ssh/"
    "/etc/shadow"
  )

  for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    if echo "$TOOL_INPUT" | grep -q "$pattern"; then
      echo "❌ BLOCKED: Cannot read sensitive file matching '$pattern'" >&2
      exit 2
    fi
  done
fi

exit 0

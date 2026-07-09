---
name: deploy
description: |
  Deployment preparation for Tennis Shot Tracker. Pre-flight checklist, PR template,
  and gh commands. Used by the deployer agent. Hard rule: never merge autonomously.
---

# Deploy Skill

## Pre-Flight Checklist

All steps must pass before creating the PR.

```bash
#!/bin/bash
set -euo pipefail

echo "=== Tennis Shot Tracker Pre-Flight ==="

echo "1/6 Go build..."
cd backend/ && go build ./... && echo "✅" && cd ..

echo "2/6 Go tests..."
cd backend/ && go test ./... && echo "✅" && cd ..

echo "3/6 Go vet..."
cd backend/ && go vet ./... && echo "✅" && cd ..

echo "4/6 Python type check..."
if [ -d cv/ ] && [ -f cv/requirements.txt ]; then
  cd cv/ && python -m mypy pipeline/ --strict 2>/dev/null && echo "✅" && cd ..
else
  echo "skip (cv/ not yet created)"
fi

echo "5/6 Swift build..."
if [ -d ios/ ]; then
  xcodebuild build \
    -scheme TennisShotTracker \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    2>/dev/null && echo "✅" || echo "⚠️ Swift build failed (check ios/)"
else
  echo "skip (ios/ not yet created)"
fi

echo "6/6 Secrets scan..."
if git diff main --no-color 2>/dev/null | grep -iEq "(api[_-]?key|secret|password|token)=['\"][^'\"]+"; then
  echo "❌ POTENTIAL SECRET IN DIFF"
  exit 1
fi
echo "✅"

echo "=== Pre-flight passed ✅ ==="
```

## PR Template

```markdown
## Tennis Shot Tracker — <Title>

### Summary
<2-3 sentences: what this adds, why it matters>

### Links
- Spec: `docs/specs/<file>`
- Plan: `docs/plans/<file>`
- Review: `docs/plans/<file>` — **APPROVED [WITH FIXES]**
- Security: `docs/plans/<file>` — **PASS**

### Changes
**Backend (Go)**
- <change>

**iOS (Swift)**
- <change or "N/A">

**CV Pipeline (Python)**
- <change or "N/A">

### Acceptance Criteria
- [x] <from spec>

### Manual Testing
1. <step>
2. <expected>

### DB Migration
`goose -dir backend/migrations postgres "$DATABASE_URL" up` | N/A

### Rollback
`git revert <sha>` | `goose -dir backend/migrations postgres "$DATABASE_URL" down-to <version>` for migration rollback

---
*AI-generated PR. Human review required before merge.*
```

## PR Creation Commands
```bash
cat > /tmp/pr-body.md << 'PREOF'
<PR body here>
PREOF

gh pr create \
  --title "feat(<scope>): <title>" \
  --body-file /tmp/pr-body.md \
  --base main \
  --label "ai-generated"

gh pr view --json number,url
```

## Hard Rules
- NEVER run `gh pr merge` or `gh pr merge --auto`
- NEVER run `git push origin main`
- ALWAYS label PRs as `ai-generated`
- ALWAYS include rollback plan
- If pre-flight fails: stop, report, do not create PR

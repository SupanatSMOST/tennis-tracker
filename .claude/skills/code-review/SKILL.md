---
name: code-review
description: |
  Code review checklist and methodology for Tennis Shot Tracker (Go + Swift + Python).
  Activated when any agent needs to evaluate code quality across layers.
---

# Code Review Skill

## Pass 1 — Structural Scan (30 seconds)
- How many files changed? Which layers (backend/ios/cv)?
- New dependencies added (go.mod, requirements.txt, Package.swift)?
- Commit history clean?

## Pass 2 — Spec Compliance (2 minutes)
For each acceptance criterion in the spec:
- Is it implemented?
- Is it tested?
- Is it user-facing and documented if needed?

## Pass 3 — Line-by-Line (bulk of time)

### Go
**Correctness:**
- Errors returned and checked — no bare `_` on error returns
- Context propagated through the call chain
- DB transactions committed or rolled back in all branches
- No goroutine leaks (deferred cancel, channel closes)

**Type safety:**
- UUID as `uuid.UUID`, not `string`
- Nullable DB columns as `*T` or `sql.NullX`
- No untyped interface{} / any where a concrete type fits

**Performance:**
- N+1 queries (load related records in bulk, not per row)
- Missing pagination on list endpoints
- Unnecessary JSON marshal/unmarshal in hot paths

### Swift
**Correctness:**
- All async I/O uses `async/await`; no completion handlers
- No force-unwrap `!` on realistically-nil optionals
- Proper `MainActor` annotation for UI updates from background tasks

**Architecture:**
- Business logic in ViewModels, not Views
- No direct network calls from Views
- Token read from Keychain, not UserDefaults

### Python (CV)
**Correctness:**
- Type hints on all function signatures
- NumPy 2.x compatible (no `np.Inf`, no `np.bool` — use `np.bool_`)
- PyTorch 2.x compatible (no deprecated `torch.load` without `weights_only=True`)

**No training code in production pipeline:**
- `model.train()` should not appear in pipeline/ (only in experiments/)

## Pass 4 — Test Review
- Does each AC have at least one test?
- Error paths tested, not just happy paths?
- Tests deterministic (no sleep, no random without seeding)?
- Go: table-driven where there are multiple cases?

## Pass 5 — Security Quick Check
- User input validated before use
- No secrets in code
- Auth middleware on all protected routes
- No sensitive data in logs

## Comment Format
```
[SEVERITY] path/file.go:42 — <issue>
  Context: <why this matters>
  Fix: <specific change>
```

Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO

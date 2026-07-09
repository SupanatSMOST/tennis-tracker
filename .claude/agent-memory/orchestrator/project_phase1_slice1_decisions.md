---
name: phase1-slice1-decisions
description: Gate-1 approved decisions for Phase 1 Slice 1 (backend + auth foundation) — resolves the spec's four open questions
metadata:
  type: project
---

Gate 1 for the backend/auth foundation slice was approved 2026-07-09. The spec's four open questions were resolved by the human as follows, and are binding for architecture + implementation:

- **OQ-1 (profile row on signup): YES** — `POST /auth/signup` eagerly inserts the 1:1 `profile` row with `display_name = username`.
- **OQ-2 (auto-login): YES** — signup returns `201 + { user_id, username, token }` (same JWT `login` issues). `login` remains a token issuer too.
- **OQ-3 (/health DB probe): NO** — `/health` is pure liveness, returns 200 whenever the process is up, never probes DB, no 503 path this slice.
- **OQ-4 (password policy):** min 8 characters AND reject > 72 bytes with 400 (explicit, so bcrypt's silent 72-byte truncation is never reached). Non-empty subsumed by min-8.

**Why:** These pin down the underspecified points in `docs/specs/spec-backend-auth-foundation-2026-07-09.md` before coding.
**How to apply:** If a later slice revisits signup/health/password handling, these are the established baselines — don't silently diverge.

See [[tennis-pipeline-env-constraints]] for the git/branch constraints on this run.

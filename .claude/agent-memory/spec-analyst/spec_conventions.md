---
name: spec-conventions
description: Self-derived working note on how to keep Tennis Shot Tracker specs faithful to DESIGN.md and testable
metadata:
  type: project
---

Working conventions for writing specs in this project (self-derived while writing the backend-auth-foundation spec; not user-given guidance).

- DESIGN.md is column-level; its stated nullability is authoritative. Only mark nullable what it marks nullable — adding NOT NULL/DEFAULT/ON DELETE where DESIGN.md is silent is drift, because reviewers diff §5 against DESIGN.md lines 115-154.
- Genuinely-underspecified DDL details (UUID generation strategy, FK ON DELETE, timestamp defaults) go in an Assumptions or Open Questions section with rationale, NOT silently baked into the DDL.
- "UUIDs for all primary keys" has a deliberate exception: `match_summary` uses composite PK `(match_id, zone)` with no surrogate id. Don't over-apply the blanket rule.
- Any auth/middleware acceptance criterion needs a protected route to test against. If none is in scope, define the minimal one (`GET /me`) and justify it as "what auth itself needs," else the AC is untestable and the middleware is dead code.

See [[project-auth]].

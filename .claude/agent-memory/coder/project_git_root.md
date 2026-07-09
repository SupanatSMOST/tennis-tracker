---
name: project-git-root
description: git repo root is SS-Persona/ not tennis/; staging paths must be relative to that root
metadata:
  type: project
---

The git repository root is `/Users/supanat.suwanjuta/Documents/SS-Persona/` (one level above `tennis/`).

When staging files created under `tennis/backend/`, the correct git-relative paths are `tennis/backend/go.mod`, `tennis/backend/cmd/server/main.go`, etc. — NOT `backend/go.mod`.

**Why:** `git add backend/go.mod` from the repo root fails with "pathspec did not match any files". Must prefix with `tennis/`.

**How to apply:** Always run `git -C /Users/supanat.suwanjuta/Documents/SS-Persona add tennis/backend/<file>` (explicit paths only, never `-A` or `.` from repo root).

---
name: tennis-repo-diff-gotcha
description: This repo mixes multiple unrelated git histories; never diff audits against main
metadata:
  type: project
---

The tennis working directory contains MULTIPLE UNRELATED git histories (webapp/,
python/, pokebot/, mql5 EA work, and the tennis backend all share the tree but not a
common ancestor).

**Why:** Diffing an audit scope against `main` shows ~341 phantom "deleted" files that
are cross-history noise, not the work under review.

**How to apply:** For any security audit in this repo, scope the diff against the
slice's stated base commit (e.g. `git diff <base>..HEAD -- 'tennis/backend/'`), never
against `main`. Confine grep/audit to the specific subtree named in the task
(the tennis Go backend lives under `tennis/backend/`).

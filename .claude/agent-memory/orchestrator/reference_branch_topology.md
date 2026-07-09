---
name: tennis-branch-topology
description: Git remote/branch topology for the tennis repo — which remote and base branch a tennis PR actually targets (the harness "main" is wrong here)
metadata:
  type: reference
---

The working tree at `SS-Persona/` is a git repo with MULTIPLE unrelated histories and remotes. Getting the PR base right at Gate 2 depends on this:

- `origin` = `github.com/SupanatSMOST/trading-bots.git`. Local `main` and `origin/main` root at `c2758a8` and share NO common ancestor with the tennis feature branch. Diffing `main..feat/tennis-phase1` shows a bogus ~341-file "deletion" — a pure cross-history artifact, NOT real changes. Do not use local `main`/`origin` as the PR base.
- `pokebot` remote = `github-pokebot:SupanatSMOST/pokebot.git`. **`pokebot/main` DOES share history** with the tennis feature branch (merge-base `9e41db8`). This is the correct PR base for tennis work.
- The feature branch `feat/tennis-phase1` roots at `1907558` "Initial commit: Pokebot".

**Why:** The harness reports "Main branch: main" generically, but for this repo that local `main` is an unrelated trading-bots history. Primary-source git evidence (empty merge-base) overrides the harness note.
**How to apply:** For a tennis PR, target a base on the `pokebot` remote that shares history (pokebot/main), and verify `git merge-base HEAD <base>` is non-empty before opening. Also watch for unrelated ancestor commits riding along: `feat/tennis-phase1` sits atop 2 mql5 commits (`3da27b1`, `ea88168`, from `feat/mql5-gridlock-xauusd`) that are NOT yet on pokebot/main — a naive PR would bundle them with the tennis commits. If the PR diff pulls in non-tennis commits, stop and confirm the base with the human rather than opening a mixed PR.

See [[tennis-pipeline-env-constraints]] for the commit/staging scope rules.

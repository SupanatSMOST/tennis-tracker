# Agentic SDLC Pipeline

An autonomous software development lifecycle powered by Claude Code agents.
Humans participate at exactly **two gates** — everything else runs autonomously.

```
HUMAN INTENT → [Gate 1: Spec Approval] → Autonomous Pipeline → [Gate 2: PR Review] → Deployed
```

## Architecture

### The Two Gates

| Gate | Who | What | When |
|------|-----|------|------|
| **Gate 1** | Human | Approves the spec | Before any code is written |
| **Gate 2** | Human | Reviews and merges PR | Before code reaches main |

### The Autonomous Pipeline

Between the gates, seven specialized agents work in sequence:

```
spec-analyst → architect → coder ⇄ test-writer → reviewer → security-auditor → deployer
                                       ↑                          |
                                       └── fix loop (max 3) ─────┘
```

| Agent | Role | Model | Writes To |
|-------|------|-------|-----------|
| `spec-analyst` | Requirements → structured spec | Opus | `docs/specs/` |
| `architect` | Spec → plan + task breakdown | Opus | `docs/plans/` |
| `coder` | Implements one task at a time | Sonnet | `src/` |
| `test-writer` | Writes tests for code changes | Sonnet | `tests/` |
| `reviewer` | Code review + auto-fixes | Opus | `docs/plans/`, minor `src/` fixes |
| `security-auditor` | Security audit (OWASP, deps) | Opus | `docs/plans/` |
| `deployer` | Creates PR (never merges) | Sonnet | Git/GitHub |
| `monitor` | Post-deploy health + feedback | Sonnet | `docs/plans/`, GitHub Issues |
| `orchestrator` | Conducts the full pipeline | Opus | Delegates only |

### Governance Layers

```
Layer 1: managed-settings.json    ← Enterprise policy (cannot be overridden)
Layer 2: .claude/hooks/           ← Deterministic enforcement (not model-dependent)
Layer 3: CLAUDE.md                ← Conventions and boundaries (model-dependent)
Layer 4: Agent definitions        ← Role constraints and tool restrictions
Layer 5: Skill definitions        ← Task-specific methodology
```

## Quick Start

### 1. Setup
```bash
# Clone and install
git clone <repo> && cd <repo>
pnpm install

# Make hooks executable
chmod +x .claude/hooks/*.sh

# Verify Claude Code configuration
claude /status
```

### 2. Run a Feature
```bash
# Start the orchestrator with your intent
claude "Build a user authentication system with JWT tokens, email/password login,
and role-based access control. Support admin and regular user roles."
```

The orchestrator will:
1. Generate a spec → **pause for your approval**
2. Plan the architecture and break it into tasks
3. Implement each task, write tests, self-review
4. Run security audit
5. Create a PR → **pause for your review**

### 3. Review and Merge
```bash
# Review the PR
gh pr view <number>
gh pr diff <number>

# If satisfied, merge
gh pr merge <number>
```

### 4. Post-Deploy Monitoring
```bash
# After merge, run the monitor
claude "Run post-deploy monitoring for PR #<number> in staging"
```

## File Structure

```
.claude/
├── agents/                    # Agent definitions
│   ├── orchestrator.md        # Lead conductor
│   ├── spec-analyst.md        # Requirements engineering
│   ├── architect.md           # System design + task planning
│   ├── coder.md               # Code implementation
│   ├── test-writer.md         # Test creation + execution
│   ├── reviewer.md            # Code review + auto-fix
│   ├── security-auditor.md    # Security analysis
│   ├── deployer.md            # PR creation
│   └── monitor.md             # Post-deploy observability
├── skills/                    # Reusable skill modules
│   ├── code-review/SKILL.md   # Review checklist + patterns
│   ├── deploy/SKILL.md        # Deployment checklist + templates
│   ├── run-tests/SKILL.md     # Test execution + coverage
│   └── security-scan/SKILL.md # Security grep patterns + OWASP
├── hooks/                     # Deterministic lifecycle hooks
│   ├── pre-tool-use.sh        # Block dangerous operations
│   ├── post-tool-use.sh       # Validate quality after changes
│   └── stop.sh                # Verify completion criteria
├── managed-settings.json      # Enterprise governance policy
└── agent-memory/              # Persistent agent learnings (gitignored)

CLAUDE.md                      # Project intelligence (symlink to AGENTS.md)
docs/
├── specs/                     # Approved specifications
├── plans/                     # Plans, task lists, reviews, audits
└── architecture/              # ADRs, system diagrams
```

## Customization

### Adding a New Agent
Create a `.md` file in `.claude/agents/` with YAML frontmatter:

```markdown
---
name: my-agent
description: |
  One paragraph explaining WHEN to use this agent and WHAT it returns.
  This drives automatic delegation — write it as a trigger condition.
tools:
  - Read
  - Write
  - Bash
model: sonnet
memory: project
maxTurns: 20
---

# My Agent

System prompt and instructions here...
```

### Adding a New Skill
Create a directory in `.claude/skills/` with a `SKILL.md`:

```markdown
---
name: my-skill
description: |
  What this skill teaches and when it's activated.
---

# My Skill

Reusable methodology, checklists, commands, and templates...
```

### Adding a New Hook
Add a script in `.claude/hooks/` and register it in `managed-settings.json`.
Remember: **exit 2 = block, exit 1 = warn, exit 0 = allow**.

## Error Recovery

The orchestrator has built-in retry logic:

| Failure | Retries | Then |
|---------|---------|------|
| Coder blocked | 3 | Escalate to human |
| Tests find bugs | 3 | Escalate to human |
| Review needs fixes | 2 | Escalate to human |
| Security audit fails | 2 | Escalate to human |
| Deploy blocked | 2 | Escalate to human |

## Security

- `managed-settings.json` locks down permissions at the enterprise level
- Hooks enforce boundaries deterministically (not model-dependent)
- The deployer agent has `disable-model-invocation: true` — it cannot autonomously decide to deploy
- No agent can push to main, merge PRs, or access secrets
- All PRs are labeled `ai-generated` for audit traceability
- Post-commit hooks scan for accidentally committed secrets

## Cost Considerations

Multi-agent pipelines consume significantly more tokens than single conversations.
Anthropic's data shows ~15x token usage for multi-agent vs chat. To manage costs:

- Use **Opus** only for high-judgment tasks (spec, architecture, review, security)
- Use **Sonnet** for execution tasks (coding, testing, deploying, monitoring)
- Set `maxTurns` on every agent to prevent runaway loops
- Set `--max-budget-usd` when running in CI
- Monitor token usage per feature and establish per-feature budgets

# Tennis Shot Tracker — Project Intelligence

> Loaded at session start. Single source of truth for all agents and subagents.
> Two human gates: Gate 1 (spec approval) → Gate 2 (PR review). Everything in between is autonomous.

## Project

iOS-first app that records a tennis session on video and stores, per shot, which court zone the ball landed in.

**Stack:** Go + PostgreSQL (backend) · Swift/SwiftUI (iOS) · Python (CV pipeline)
**Current phase:** Phase 0 step 1 ✅ done. Awaiting footage for steps 2 & 3 (see SPIKE_RESULT.md).
**Phase 1 gate:** bounce localized within ~one zone width on phone footage → proceed. Fall back to manual tap-to-tag if not.

## Build & Test

```bash
# Backend (Go)
go build ./...
go test ./...
go vet ./...

# CV pipeline (Python)
cd cv/
python -m pytest
python -m pytest -k "<test name>"

# iOS (Swift)
xcodebuild test -scheme TennisShotTracker -destination 'platform=iOS Simulator,name=iPhone 16'

# Lint
golangci-lint run ./...
ruff check cv/
swiftlint

# DB migrations
goose -dir backend/migrations postgres "$DATABASE_URL" up
```

## Project Layout

```
backend/              # Go API server
├── cmd/              # main packages (server entrypoint)
├── internal/
│   ├── handler/      # HTTP route handlers
│   ├── service/      # Business logic
│   ├── store/        # DB access (PostgreSQL via pgx)
│   └── model/        # Domain types
├── migrations/       # SQL migration files (goose)
└── go.mod

cv/                   # Python CV pipeline
├── pipeline/         # Ball detect, bounce detect, zone classify
├── tests/
└── requirements.txt

ios/                  # Swift/SwiftUI iOS app
├── TennisShotTracker/
│   ├── Views/        # SwiftUI views
│   ├── ViewModels/   # ObservableObject VMs
│   ├── Services/     # API client, CoreML runner
│   ├── Models/       # Codable types
│   └── Utils/
└── TennisShotTrackerTests/

spike/                # Phase 0 throwaway (gitignored)
docs/
├── specs/            # Approved spec documents (spec-*.md)
├── plans/            # Plans, task lists, reviews, audits (plan-*.md)
└── architecture/     # ADRs, system diagrams
.claude/
├── agents/           # Subagent definitions
├── skills/           # Reusable skill definitions
├── hooks/            # Lifecycle hook scripts
```

## Architecture Decisions (locked)

| Decision | Choice | Reason |
|----------|--------|--------|
| Landing capture | Auto CV/ML from video | On-device CoreML, post-recording |
| Player differentiation | Out of scope (v1) | Separate problem |
| Backend | Go + PostgreSQL | Consistent with pokebot stack |
| Auth | bcrypt + long-lived JWT in Keychain | Single-user personal app |
| iOS framework | Native Swift/SwiftUI | Best camera + CoreML |
| CV location | On-device only (v1) | Privacy, offline |
| Phase 0 target | Public footage first, then own phone footage | De-risk before building |

## Data Model (five tables)

`user_login` · `profile` · `match` · `record` (per-shot source of truth) · `match_summary` (derived cache)

Zone taxonomy A (CV): front-court-left/right, baseline-left/right, out-left/right/behind.
Zone taxonomy B (manual, v2): net events.

## Conventions

### Go
- Errors returned, never panicked (except truly unrecoverable)
- `pgx/v5` for Postgres; no ORM
- UUIDs for all primary keys (`uuid.UUID`)
- Structured logging via `slog`

### Python (CV)
- `pytest` for all tests
- Type hints required (`mypy` clean)
- No training in CV pipeline — pretrained weights only

### Swift
- SwiftUI + MVVM; ViewModels as `@Observable`
- Async/await for all I/O (no completion handlers)
- Keychain wrapper for token storage

### Universal
- Commits: conventional format `type(scope): message`
- Branches: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`
- PRs: never merge to main autonomously; always label `ai-generated`
- No secrets in code; no `.env` committed

## Phase Roadmap

- **Phase 0** — CV spike (steps 2 & 3 blocked on footage from user)
- **Phase 1** — Go API + Postgres schema + iOS shell + auth + manual record entry
- **Phase 2** — Camera framing + 4-corner tap → homography + record + store video
- **Phase 3** — CV integration (wire proven Phase-0 pipeline into record flow)
- **Phase 4** — Stats/home aggregation and polish
- **v2** — Net events, auto court-line detection, real-time processing

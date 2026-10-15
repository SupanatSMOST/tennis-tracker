# Tennis Shot Tracker

An iOS-first tennis session tracker. The app is designed to record a court-side video, capture a court calibration, review detected ball bounces, and save each bounce as a court-zone shot. The current product scope is post-recording landing detection; player identification and real-time analysis are out of scope for v1.

## Project status

The app foundation includes a native Swift/SwiftUI client (`ios/`), a Go API (`backend/`), PostgreSQL migrations, authentication, match/record endpoints, camera capture, and four-corner court calibration. Automatic bounce localization is still experimental and has not passed its real-footage validation gate. The Phase 0 spike reports zero bounces on a degraded smoke clip; this does not establish performance on representative footage. Treat automatic results as unvalidated until the evaluation protocol in `docs/PHASE1_EVA_HELION.md` passes.

## Architecture

- iOS client: native Swift/SwiftUI; reusable package in `ios/TennisCore`.
- API: Go services in `backend/`.
- Persistence: PostgreSQL schema and goose migrations in `backend/migrations/`.
- Local orchestration: Docker Compose starts PostgreSQL, runs migrations, then starts the API.
- CV direction: post-recording ball tracking and bounce localization, with four-corner homography mapping to court coordinates. The CoreML-versus-worker decision and confidence policy are documented in `docs/PHASE1_EVA_HELION.md`.

Individual shot records are the source of truth; per-zone match summaries are derived. The supported v1 events are landing zones. Net events and other non-landing outcomes require a separate detection path or explicit manual tagging.

## Development

Requirements: Go version specified by `backend/go.mod`, Docker Compose, and Xcode/Swift toolchain compatible with the iOS project. For backend unit tests:

```sh
cd backend
go test ./...
go vet ./...
```

Database-backed tests may require `DATABASE_URL`; inspect test setup and migrations before running them. For local services, copy `.env.example` to `.env`, supply local-only credentials and a strong JWT signing key, then run:

```sh
docker compose up --build
```

Do not commit `.env`, secrets, or model weights. For iOS core package tests:

```sh
cd ios/TennisCore
swift test
```

Refer to `DEPLOY.md` for deployment guidance. Validate against a clean environment before release; successful compilation alone does not validate CV accuracy.

## Documentation

- `DESIGN.md`: product scope, schema, app flow, and phase plan.
- `SPIKE.md` and `SPIKE_RESULT.md`: CV feasibility experiment and current limitations.
- `docs/PHASE1_EVA_HELION.md`: ADR, CV result contract, test/benchmark plan, and operational next steps.

## Privacy and limitations

The design specifies on-device video/CV for v1, but inference deployment has not yet been proven. Until that decision is implemented and verified, do not claim video is processed only on-device in a shipped build. Obtain user consent for footage used in evaluation, document data retention, and verify all third-party model/data licenses before distributing model assets.

# Tennis Shot Tracker

This directory contains supporting project material. The product is an iOS-first tennis session tracker: record a session, calibrate court coordinates using four court corners, review candidate ball bounces, and store per-shot court-zone records with session summaries.

The current implementation includes a Swift/SwiftUI client, a Go API, PostgreSQL migrations, authentication, match and shot persistence, and camera/calibration flows. Automatic bounce localization remains an experimental capability: `SPIKE_RESULT.md` reports a successful pipeline smoke run but zero detected bounces on its degraded clip, and the representative public-footage and phone-footage accuracy gate remains outstanding. Do not interpret the smoke test as validated bounce detection.

For setup and development, use the repository-root `README.md`, `DEPLOY.md`, `.env.example`, and `docker-compose.yml`. For intended scope and CV caveats, see `DESIGN.md`, `SPIKE.md`, and `SPIKE_RESULT.md`. This README replaces the unrelated generic agentic-SDLC overview that previously occupied this path.

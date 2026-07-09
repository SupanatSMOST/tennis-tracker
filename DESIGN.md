# Tennis Shot Tracker — Design & Plan (v0)

> Status: **planning only, no code yet.** iOS-first mobile app to record a tennis
> session on video and store, per shot, **which court zone the ball landed in**.
> Backend: Go + PostgreSQL.

## Decisions locked (from kickoff)

| Question | Decision |
|---|---|
| Landing capture | **Automatic CV/ML** — detect where the ball bounces from video |
| Player differentiation | **Out of scope.** We track *landings only*, not who hit the shot |
| Menu-2 camera step | **Frame/quality check only** (no live detection) |
| Backend | **Go** (consistent with pokebot stack) + PostgreSQL |
| Auth | user/pass only, session never expires until app deleted, JWT wraps `user_id` (UUID) |
| iOS framework | **Native Swift/SwiftUI** (best camera + CoreML integration) |
| Video + CV location | **On-device only** for v1 — video stays on phone, CV runs via CoreML |
| Phase 0 footage | Prototype on **public tennis footage** first, validate on own footage later |

## ⚠️ The one risk that dominates everything

Automatic ball-landing detection from a **single phone camera** is a Hawk-Eye-class
problem: the ball is small, fast, and motion-blurred; it can be occluded; and a pixel
must be mapped to a real court position. Removing player-ID did **not** de-risk this —
they were separate problems. Nothing below is worth building until we prove the CV can
localize a bounce to roughly **one zone's width** on real footage. Hence Phase 0.

---

## Phase 0 — CV feasibility spike (do this FIRST, throwaway code)

Goal: answer one yes/no question on **your own court + your own phone footage**:

> Can the pipeline localize a ball bounce to within one zone's width, consistently?

Prototype on **public tennis footage** first to prove the pipeline stages work, then
validate on real footage from a phone at your own court before committing to Phase 1.

Pipeline to prototype (each stage independently checkable):

1. **Court calibration → homography.**
   User taps the **4 court corners** once per camera position. This yields an
   image→court coordinate mapping (homography) that turns any pixel into a real
   court position. *This same step doubles as the Menu-2 "camera can see all
   positions" check — if all 4 corners are tappable and in frame, the court is framed.*
   - Auto court-line detection is a *second* hard problem — **explicitly off the
     critical path.** Manual corner-tap is the reliable v1.
2. **Ball detection + tracking** across frames.
   Reference approach: **TrackNet-family** models (built for tiny fast balls in
   racket sports). Must verify it runs on-device via **CoreML**, otherwise offload
   to a processing service.
3. **Bounce localization** — find the frame/point where the trajectory bounces.
4. **Zone classification** — feed the bounce pixel through the homography → court
   coords → zone label.

**Processing mode: post-recording, not real-time.** Record the clip, then process it
(on-device or via a Go/Python service). Real-time ball tracking on a phone is a much
taller order and not needed for a stats app.

**Exit gate:** bounce localized within ~one zone width on your footage →
proceed to Phase 1. If not, the "automatic" premise must be revisited (manual
tap-on-playback is the ready fallback) before building the rest.

---

## Shot taxonomy — needs splitting (it's heterogeneous)

The original list mixes two different kinds of thing:

**(A) Landing zones** — fall out of the bounce + homography pipeline:
- front court left / front court right
- baseline left / baseline right
- out left / out right / out behind (beyond baseline)

**(B) Non-landing events** — do NOT come from a bounce location:
- **"not over the net"** — the ball never lands in-play; it's a net event, needs
  different detection entirely.

**Plan:** v1 detects category (A) via CV. Category (B) events like "not over the net"
are **v2**, or a **manual-tag fallback** in the review screen. Do not silently mix
them into the same detector.

Zone set is configurable; final list to be confirmed against a court diagram.

---

## App structure (iOS)

Three menus, as specified:

1. **Home** — history of records + recent statistics (aggregated counts per zone,
   recent sessions).
2. **Record** — Menu-2 flow:
   - open camera → **frame/quality check** (tap 4 court corners; confirms court is
     fully in frame *and* produces the calibration homography) →
   - record the session video →
   - after stop: run CV processing → review detected shots →
   - save record.
3. **Profile** — user profile + **logout**.

---

## Data model (PostgreSQL)

Five tables total: `user_login`, `profile`, and the three that model gameplay —
**`match`** (one session), **`record`** (one shot), **`match_summary`** (per-zone
counts, built at match end).

**Granularity: per-shot rows, not counters.** The spec says "store how many shots to
each area **and the location of this count**" — so each shot is its own row
(`record`), and per-zone counts are **derived**. Fast reads come from `match_summary`,
a rebuildable cache computed when the match ends (see below), so the Home screen never
runs a live `COUNT` yet the stored numbers are always explainable shot-by-shot.

```
user_login
  user_id        UUID  PK
  username       TEXT  UNIQUE NOT NULL
  password_hash  TEXT  NOT NULL          -- bcrypt
  created_at     TIMESTAMPTZ

profile
  user_id        UUID  PK/FK -> user_login.user_id   -- 1:1
  display_name   TEXT
  avatar_url     TEXT (nullable)
  updated_at     TIMESTAMPTZ

match                                    -- one session / match
  match_id       UUID  PK
  user_id        UUID  FK -> user_login.user_id
  location       TEXT
  court_surface  TEXT  ('hard'|'clay'|'grass'|...)
  played_at      TIMESTAMPTZ            -- match datetime
  video_ref      TEXT  (nullable; local/remote reference)
  ended_at       TIMESTAMPTZ (nullable) -- set when session ends; triggers summary
  created_at     TIMESTAMPTZ

record                                   -- one detected shot within a match
  record_id      UUID  PK
  match_id       UUID  FK -> match.match_id
  zone           TEXT  (taxonomy A; later B)
  court_x        REAL  (nullable; homography court coords)
  court_y        REAL  (nullable)
  ts_ms          INT   (nullable; offset into the clip)
  source         TEXT  ('cv'|'manual')   -- how the zone was set
  created_at     TIMESTAMPTZ

match_summary                            -- per-zone counts; derived cache
  match_id       UUID  FK -> match.match_id
  zone           TEXT
  shot_count     INT
  computed_at    TIMESTAMPTZ
  PRIMARY KEY (match_id, zone)
```

### Source of truth vs. cache
- **`record` is the source of truth** — the "location of this count" (zone + coords +
  timestamp per shot).
- **`match_summary` is a derived cache**, never hand-edited. It is **only** computed
  from `record`, so it can never silently drift.

### When `match_summary` is built
1. User ends the match → set `match.ended_at`.
2. Backend runs one aggregation:
   `SELECT zone, COUNT(*) FROM record WHERE match_id = ? GROUP BY zone`.
3. Upsert rows into `match_summary` with `computed_at = now()`.
4. If any shot in that match is later edited/deleted, **re-run the same routine** for
   that `match_id` so the summary stays consistent.

`court_surface` lives on `match` (per session), matching "store ... court surface."

> Note: at single-user volume a live `GROUP BY` over one match is already instant, so
> `match_summary` is an optimization, not a correctness requirement. It earns its place
> by (a) snapshotting session-level metrics at match-end and (b) making the Home/history
> screen a dumb fast read.

---

## Auth (as specified, with trade-off noted)

- **user/pass only.** Password stored as **bcrypt** hash in `user_login`.
- On login, backend signs a **JWT wrapping `user_id`**; all downstream calls use it.
- **Session never expires** until the app is deleted → store the long-lived token in
  the **iOS Keychain**. On launch, app reads the token and resolves `user_id` for the
  whole flow.
- Trade-off (one line, accepted): a non-expiring token can't be revoked server-side
  without extra machinery; acceptable for a personal/single-user app, revisit if it
  goes multi-user or public.

---

## Build order

- **Phase 0 — CV spike** (throwaway). Gate on bounce-localization accuracy. *Everything
  below waits on this.*
- **Phase 1 — Skeleton.** Go API + Postgres schema + iOS shell (3 menus), auth flow,
  manual record entry (tap zones) end-to-end. Proves the data path without CV.
- **Phase 2 — Calibration + record.** Camera framing + 4-corner tap → homography;
  record + store video.
- **Phase 3 — CV integration.** Wire the proven Phase-0 pipeline into the record →
  process → review → save flow.
- **Phase 4 — Stats/home** aggregation and polish.
- **v2 candidates:** "not over the net" & other net/error events; auto court-line
  detection; real-time processing; player differentiation.

## Open items to confirm before Phase 1

1. Final zone list (against a court diagram) — categories A and B.
2. Confirm TrackNet-family model runs acceptably in **CoreML on-device** (Phase 0 output).

_Resolved:_ iOS = native Swift/SwiftUI · Video + CV = on-device only · Spike on public
footage first.

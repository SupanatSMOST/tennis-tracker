# Spec: iOS App — Gameplay Screens (Phase 1, Slice 4)

**Date:** 2026-07-10
**Phase:** Phase 1 (Skeleton)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Deliver the iOS gameplay screens that let a single user run the manual
tap-to-tag record flow end-to-end against the live backend gameplay API
(`feat/backend-gameplay-crud`). Concretely: (1) a Home tab that lists the
user's matches; (2) a create-match flow that picks a court surface; (3) a
live record session where each tap on an on-device court diagram records one
shot; (4) an end-match action and a per-zone summary. This is the last piece
of the Phase 1 "manual record entry (tap zones) end-to-end" milestone
(DESIGN.md Build order) and it proves the full data path — client tap → zone
string → backend `record` row → `match_summary` counts — with **no camera and
no CV**. It builds directly on the TennisCore foundation and 3-tab shell from
Slice 2 (`spec-ios-auth-shell-2026-07-09.md`), replacing the Home and Record
tab placeholders with working screens.

## 2. Critical Architectural Constraint (non-negotiable)

**Zone classification happens ON-DEVICE, not on the server.** The backend
stores whatever zone string the client sends; it does not compute the zone.
The client is solely responsible for mapping a tap on the court diagram to one
of the six allowed zone strings. For Phase 1 this mapping is **manual
tap-to-tag** (a human taps where the ball landed) resolved by a pure-geometry
`ZoneClassifier` in TennisCore — there is no CV and no ML in this slice.

Consequences that this spec enforces:

- `ZoneClassifier` lives in TennisCore and is **pure CoreGraphics geometry**
  (`CGPoint`/`CGRect` only). It MUST NOT import UIKit or SwiftUI, so it is
  fully testable via `swift test` on macOS with no iOS runtime.
- The set of zone strings the client can ever emit is fixed by the backend
  enum (§3.1). The client never invents a zone the backend would reject.
- Because zone semantics are owned by the client, the six court cells and the
  exact string each cell maps to are pinned in this spec (§4, FR-Z1..Z5) — the
  coder is left no discretion over the taxonomy.

## 2b. Base branch note (deviation recorded for Gate 2)

The task instructed "branch off `main`." **This is not possible.** `main`
contains **no iOS code** — the entire TennisCore foundation (`APIClient`,
`HTTPTransport`, `TokenStore`, the SwiftUI app target and 3-tab shell) exists
only on the unmerged branch `feat/ios-auth-shell`. A branch off `main` would
not compile, so this slice's work branch `feat/ios-gameplay` **is based on
`feat/ios-auth-shell`**, and likewise depends on the backend routes delivered
on `feat/backend-gameplay-crud`.

The **PR-base decision is deferred to the human at Gate 2**, not resolved here:
either (a) target `feat/ios-auth-shell` as a stacked PR, or (b) rebase/retarget
onto `main` once `feat/ios-auth-shell` (and the backend gameplay branch) merge.
This spec takes no position on which; it only records that branching off `main`
was impossible and states the dependency chain so the reviewer can choose.

## 3. Scope

### 3.1 Zone strings — hard requirement (exact match to backend enum)

The client MUST emit exactly one of these six strings and no others. They must
match the backend enum byte-for-byte (lower snake_case):

```
front_court_left
front_court_right
baseline_left
baseline_right
out_left
out_right
```

Any deviation (casing, spelling, extra value, DESIGN.md's `out_behind`) is a
defect: the backend is the authority for the accepted set and it accepts only
these six in Phase 1 (see A-1 for the DESIGN.md divergence).

### In scope

- **TennisCore — `Models/MatchModels.swift`:** Codable DTOs — `MatchResponse`,
  `ShotResponse`, `SummaryEntry`, `CreateMatchRequest`, `AddShotsRequest`,
  `ShotInput`. Decoding tested via `swift test`.
- **TennisCore — `Gameplay/MatchClient.swift`:** exactly seven async methods
  wrapping the seven backend routes (§6), built on the existing APIClient seams
  (injected `HTTPTransport` + `TokenStore`, `Authorization: Bearer <token>`
  header, the existing `mapError` pattern, `.transport` wrapping for offline).
  Follows `APIClient.swift` style exactly (A-3). Tested via `StubTransport`.
- **TennisCore — `Gameplay/ZoneClassifier.swift`:** pure-geometry
  `classify(point:in:) -> String`. Six-cell court, mapping and boundary rules
  pinned in §4. Tested via `swift test`.
- **TennisCore — ViewModels** (`@Observable`, in TennisCore so they are
  `swift test`-able per the Slice-2 precedent AC22): `MatchListViewModel`,
  `RecordSessionViewModel`, `MatchSummaryViewModel`.
- **App target SwiftUI screens** (replace the Slice-2 placeholders
  `HomePlaceholderView` and `RecordPlaceholderView`): `MatchListView`,
  `CreateMatchSheet`, `RecordSessionView`, `MatchSummaryView`. Build-only this
  slice (`xcodebuild build`); no simulator/UI tests.

### Out of scope (non-goals)

- **Camera / AVFoundation / court framing / 4-corner homography.** Deferred to
  Phase 2. The court diagram here is a static schematic, not a camera overlay.
- **Any CV / CoreML.** Deferred to Phase 3. Zone comes from a human tap only.
- **`out_behind` and net-event zones** (DESIGN.md taxonomy A `out_behind`,
  taxonomy B). Not in the six-value Phase-1 enum (A-1). Deferred to v2.
- **Backend changes.** The seven routes (§6) are consumed as delivered on
  `feat/backend-gameplay-crud`; no server work in this slice.
- **Editing or deleting individual recorded shots** after they are POSTed, and
  editing a match's surface after creation. Not exposed this slice (A-6).
- **Profile-tab work.** Untouched from Slice 2 (Logout only).
- **iOS simulator / UI tests / iOS CI job.** Still deferred (no simulator
  runtime; §7). Views are compile-only this slice.
- **Video reference, location, and `played_at` on match creation.** The create
  flow sends only `court_surface`; other `match` columns are left to their
  backend defaults (A-5).

## 4. ZoneClassifier — pinned geometry (no coder discretion)

`classify(point: CGPoint, in rect: CGRect) -> String` divides `rect` into a
2-column × 3-row grid (six cells) and returns the mapped zone string.

**Columns (lateral):** split by the vertical midline `rect.midX`. "Left" here
means the **diagram viewer's** left (smaller `x`); the classifier is
self-consistent and, per §2, the client owns zone semantics, so viewer-left vs
player-left is a view-layer cosmetic concern only.
- `point.x < rect.midX` → **left** column.
- `point.x >= rect.midX` → **right** column.

**Rows (depth):** split by two horizontal lines into equal thirds of the
rect's height (A-2). With `h = rect.height`:
- **near-net row:** `rect.minY <= y < rect.minY + h/3`
- **mid row:** `rect.minY + h/3 <= y < rect.minY + 2h/3`
- **deep row:** `rect.minY + 2h/3 <= y <= rect.maxY`

The court diagram is drawn "net at top, baseline at bottom" (near-net row is
the top third). If the app draws it inverted, the row order is flipped in the
*view's* rect construction, not in the classifier — the classifier's contract
is purely "row 0 = smaller y."

**Cell → zone mapping (1:1, six cells to six strings):**

```
              LEFT column        RIGHT column
            (x < midX)         (x >= midX)
near-net  front_court_left    front_court_right
  mid     baseline_left       baseline_right
 deep     out_left            out_right
```

**Boundary ownership (half-open intervals, deterministic):** a point exactly on
a dividing line belongs to the cell on the **greater-coordinate** side. So
`x == rect.midX` → right column; `y == rect.minY + h/3` → mid row (not
near-net); `y == rect.minY + 2h/3` → deep row (not mid). Every in-rect point
resolves to exactly one cell.

**Out-of-rect handling (clamp, never nil):** the return type is non-optional
`String`; there is no "unknown" value in the six-enum and the backend rejects
anything else. If `point` lies outside `rect`, the classifier **clamps** the
point to the rect bounds (`x` into `[minX, maxX]`, `y` into `[minY, maxY]`)
before classifying, so it always returns a valid zone. The UI only makes the
court rect tappable (FR-V3), so out-of-rect is a defensive path, not a normal
one. Degenerate rect (`width <= 0` or `height <= 0`) is defined in OQ-2 with a
stated default.

## 5. Acceptance Criteria

Each criterion is independently verifiable. **TennisCore logic ACs** are proven
by `swift test`; **app-target ACs** by `xcodebuild build` + inspection (no
simulator this slice). Target: **20+ new tests on top of the existing 52
(total 72+), all green.**

### TennisCore — MatchModels decoding (`swift test`)
- [ ] AC1: `MatchResponse` decodes
  `{"id":"<string>","user_id":"<string>","court_surface":"hard","created_at":"<string>","ended_at":null}`
  with `id` and `user_id` as Swift **`String`** (not `UUID`) and `ended_at` as
  an **optional** `String?` that decodes `null` to `nil` (A-4, A-7).
- [ ] AC2: `MatchResponse` decodes a match with a non-null `ended_at` string
  into a non-nil `ended_at`, and the VM can tell "active" (`ended_at == nil`)
  from "ended" (`ended_at != nil`).
- [ ] AC3: `ShotResponse` decodes
  `{"id":"<string>","match_id":"<string>","zone":"baseline_left","source":"manual","created_at":"<string>"}`
  with all id fields as `String`.
- [ ] AC4: `SummaryEntry` decodes `{"match_id":"<string>","zone":"out_left","count":7}`
  with `count` as `Int`.
- [ ] AC5: `CreateMatchRequest` encodes to `{"court_surface":"clay"}` (exact key,
  no extra fields).
- [ ] AC6: `AddShotsRequest` containing two `ShotInput`s encodes to
  `{"shots":[{"zone":"front_court_left","source":"manual"},{"zone":"out_right","source":"manual"}]}`
  (exact key/order-independent shape; `source` defaults to `"manual"`).

### TennisCore — MatchClient behavior (`swift test`, StubTransport)
- [ ] AC7: `createMatch(surface:)` issues `POST /matches` with body
  `{"court_surface":"<surface>"}` and a `Bearer` header, and parses the returned
  `MatchResponse`.
- [ ] AC8: `listMatches()` issues `GET /matches` and parses an array of
  `MatchResponse`.
- [ ] AC9: `getMatch(id:)` issues `GET /matches/{id}` and parses one
  `MatchResponse`.
- [ ] AC10: `endMatch(id:)` issues `POST /matches/{id}/end` and parses the
  returned `MatchResponse` with a non-nil `ended_at`.
- [ ] AC11: `addShots(matchID:shots:)` issues `POST /matches/{id}/shots` with body
  `{"shots":[...]}` and parses `{"count":N}` into an `Int` count equal to the
  number of shots sent.
- [ ] AC12: `listShots(matchID:)` issues `GET /matches/{id}/shots` and parses an
  array of `ShotResponse`.
- [ ] AC13: `getSummary(matchID:)` issues `GET /matches/{id}/summary` and parses
  an array of `SummaryEntry`.
- [ ] AC14: Every one of the seven methods sends
  `Authorization: Bearer <token>` using the injected `TokenStore`'s token.
- [ ] AC15: A `401` from any method maps via the existing `mapError` to the
  invalid-credentials client error (same mapping as `APIClient`); a `400` maps
  to the validation error. (404 handling per A-8/OQ-4.)
- [ ] AC16: A simulated transport/offline failure surfaces the `.transport`
  error variant (same wrapping as `APIClient`), distinct from an HTTP-status
  error.
- [ ] AC17: All MatchClient tests pass with no live backend and no
  `localhost:8080` reachable (transport is the injected `StubTransport`).

### TennisCore — ZoneClassifier geometry (`swift test`)
- [ ] AC18: For a unit rect `CGRect(0,0,120,120)`, the six cell centers map 1:1
  to the six zone strings per the §4 table: `(30,20)→front_court_left`,
  `(90,20)→front_court_right`, `(30,60)→baseline_left`, `(90,60)→baseline_right`,
  `(30,100)→out_left`, `(90,100)→out_right`.
- [ ] AC19: The vertical midline is right-owned: `x == rect.midX` classifies to
  the **right** column (e.g. `(60,20)→front_court_right`).
- [ ] AC20: The two horizontal lines are greater-coordinate-owned:
  `y == h/3` classifies to the **mid** row and `y == 2h/3` classifies to the
  **deep** row (e.g. on a 120-tall rect, `(30,40)→baseline_left`,
  `(30,80)→out_left`).
- [ ] AC21: The four corners resolve deterministically — top-left→
  `front_court_left`, top-right→`front_court_right`, bottom-left→`out_left`,
  bottom-right→`out_right` (with midX/midpoints owned per AC19/AC20).
- [ ] AC22: An out-of-rect point clamps and still returns a valid zone: a point
  left/above the rect → `front_court_left`; a point right/below the rect →
  `out_right`. The function never returns an empty or non-enum string.
- [ ] AC23: `classify` never returns a string outside the six-value set for any
  finite input point (property-style check over a grid of sample points).

### TennisCore — ViewModels (`swift test`, StubTransport)
- [ ] AC24: **RecordSessionViewModel — transport-failure retention (load-bearing,
  OQ-3).** With `addShots` stubbed to throw the `.transport` error, recording a
  tapped shot leaves that shot in the VM's local list (queued / marked-failed,
  **not removed**) and the running counter still reflects it. A shot is never
  silently dropped because the network blipped.
- [ ] AC25: **RecordSessionViewModel — happy path.** N taps append N shots to the
  local list in tap order; the exposed count equals N; the end-match action calls
  `endMatch(id:)` on the client with the active match id.
- [ ] AC26: **MatchListViewModel — active/ended classification (FR-VM1 routing).**
  A `MatchResponse` with `ended_at == nil` classifies as **active** (routes to
  session); one with a non-nil `ended_at` classifies as **ended** (routes to
  summary).
- [ ] AC27: **MatchSummaryViewModel — load.** With `getSummary` stubbed to return
  a list of `SummaryEntry`, the VM exposes those per-zone counts for display; a
  stubbed error surfaces as a load error, not a crash.

### App target — build only (`xcodebuild build`, inspection)
- [ ] AC28: `xcodebuild build` of the `TennisShotTracker` app target succeeds
  (compile-only; no simulator, no test run).
- [ ] AC29: By inspection, `HomePlaceholderView` and `RecordPlaceholderView` are
  replaced/superseded by `MatchListView` and `RecordSessionView`; the Home tab
  shows the match list and the Record entry leads into the create/session flow.
- [ ] AC30: By inspection, no networking, decoding, zone-mapping, or shot-list
  logic lives in the app target — all of it is in TennisCore (MatchClient,
  ZoneClassifier, the three ViewModels). Views observe `@Observable` VMs.
- [ ] AC31: By inspection, no new third-party dependency is added to
  `Package.swift` (or the app target) beyond what Slice 2 already declared.

## 6. API Contract (consumed as delivered on `feat/backend-gameplay-crud`)

All routes require `Authorization: Bearer <token>`. Bodies are JSON. `id`,
`user_id`, `match_id` are JSON **strings** (backend serializes UUIDs as
strings, per the Slice-2 verified contract). Timestamps are JSON strings;
`ended_at` may be `null`.

| # | Method & path | Request body | Success body |
|---|---|---|---|
| 1 | `POST /matches` | `{"court_surface":"hard"\|"clay"\|"grass"}` | `{id,user_id,court_surface,created_at,ended_at}` |
| 2 | `GET /matches` | — | `[ MatchResponse, … ]` |
| 3 | `GET /matches/{id}` | — | `MatchResponse` |
| 4 | `POST /matches/{id}/end` | — | `MatchResponse` (with `ended_at` set) |
| 5 | `POST /matches/{id}/shots` | `{"shots":[{"zone":"…","source":"manual"},…]}` | `{"count":N}` |
| 6 | `GET /matches/{id}/shots` | — | `[ {id,match_id,zone,source,created_at}, … ]` |
| 7 | `GET /matches/{id}/summary` | — | `[ {match_id,zone,count}, … ]` |

**Error shape:** the uniform `{"error":"<message>"}` from Slice 1/2. Client
status mapping reuses the existing `mapError`: `400`→validation, `401`→invalid
credentials, `409`→username taken (not expected on these routes), else→server.
`404` (unknown match id, routes 3/4/5/6/7) is **not** a distinct case in the
existing `mapError`; per "follow APIClient style exactly," it currently falls
through to `else→server`. This gap is flagged (A-8, OQ-4) rather than silently
patched.

## 7. Functional Requirements

### iOS (Swift) — TennisCore

- **FR-M1:** `Models/MatchModels.swift` defines the six Codable DTOs
  (`MatchResponse`, `ShotResponse`, `SummaryEntry`, `CreateMatchRequest`,
  `AddShotsRequest`, `ShotInput`). All UUID-bearing fields are `String`;
  `MatchResponse.ended_at` is `String?`. Timestamp decoding strategy per A-7.
- **FR-M2:** `Gameplay/MatchClient.swift` exposes exactly seven async methods,
  one per route in §6, each `async throws`, returning the decoded model. No
  completion handlers (CLAUDE.md Swift convention). The `POST /matches/{id}/shots`
  response `{"count":N}` has **no named DTO** (the six DTOs in FR-M1 are the full
  set); it is decoded inline (e.g. a private nested type) and `addShots` returns
  the `Int` count. "Exactly six DTOs" is not a prohibition on decoding this
  response.
- **FR-M3:** MatchClient is built on the existing APIClient seams: it takes an
  injected `HTTPTransport` and `TokenStore`, builds requests via the same
  `buildRequest`-style helper, attaches `Authorization: Bearer <token>`, maps
  HTTP status via the existing `mapError`, and wraps transport failures via the
  existing `.transport` path. It follows `APIClient.swift` style exactly (A-3);
  whether it is a peer type or extends the shared request machinery is an
  implementation detail so long as no logic is duplicated divergently.
- **FR-Z1:** `Gameplay/ZoneClassifier.swift` exposes
  `classify(point: CGPoint, in rect: CGRect) -> String`, pure CoreGraphics, no
  UIKit/SwiftUI import (so it is macOS-`swift test`-able).
- **FR-Z2:** Six-cell 2×3 grid, columns by `rect.midX`, rows by equal thirds of
  height, per §4.
- **FR-Z3:** Cell→zone mapping exactly the §4 table.
- **FR-Z4:** Boundary ownership: greater-coordinate side owns the dividing line
  (§4), so classification is total and deterministic.
- **FR-Z5:** Out-of-rect points are clamped to the rect before classifying; the
  function always returns one of the six strings (§4).
- **FR-VM1:** `MatchListViewModel` (`@Observable`) loads matches via
  `listMatches()`, exposes them for display, triggers create via
  `createMatch(surface:)`, and surfaces load/create errors. It classifies each
  match as active (`ended_at == nil`) or ended for routing (FR-V2).
- **FR-VM2:** `RecordSessionViewModel` (`@Observable`) holds the active match
  id, keeps a **local ordered shot list** appended on each tap, and calls
  `addShots(matchID:shots:)` per the flush policy in OQ-3 (default: one shot per
  tap, POSTed immediately). It exposes the running shot count and the last-N
  shots for display, and an end-match action calling `endMatch(id:)`. On a
  transport error the local list is **never dropped** (OQ-3).
- **FR-VM3:** `MatchSummaryViewModel` (`@Observable`) loads per-zone counts via
  `getSummary(matchID:)` and exposes them for the summary view, surfacing load
  errors.

### iOS (Swift) — app target

- **FR-V1:** `MatchListView` replaces `HomePlaceholderView` on the Home tab:
  lists matches with a court-surface badge and a date, ordered per OQ-5
  (default: most-recent first). A FAB (or toolbar +) presents `CreateMatchSheet`.
- **FR-V2:** Tapping a match routes by state: an **active** match
  (`ended_at == nil`) opens `RecordSessionView`; an **ended** match opens
  `MatchSummaryView` (read-only, A-6).
- **FR-V3:** `CreateMatchSheet` presents a court-surface picker (hard / clay /
  grass) and a confirm action that calls the VM's create, then routes into the
  new match's `RecordSessionView`.
- **FR-V4:** `RecordSessionView` replaces `RecordPlaceholderView`: draws the
  static six-zone court diagram, makes **only the court rect** tappable, and on
  each tap calls `ZoneClassifier.classify(point:in:)` with the tap point and the
  diagram's rect, then records the resulting zone via the VM. Shows a live shot
  counter, the last-N shots list, and an End Match button (routes to summary on
  success).
- **FR-V5:** `MatchSummaryView` renders the per-zone counts as a bar or grid
  from `MatchSummaryViewModel`.
- **FR-V6:** No testable logic in the app target (AC30); ViewModels are
  `@Observable` and live in TennisCore.

### Backend (Go)
- N/A for this slice. The seven routes (§6) are consumed as delivered on
  `feat/backend-gameplay-crud`; no server work.

### CV Pipeline (Python)
- N/A for this slice (explicit non-goal; zone comes from a human tap, §2).

## 8. Data Model Changes

**None.** No database and no schema changes in this slice. The five tables and
their columns were created in Slice 1 (`spec-backend-auth-foundation`). The
client consumes the API only. The load-bearing client-side data facts:

- All UUID-bearing fields (`id`, `user_id`, `match_id`) are decoded as Swift
  `String`, never `UUID` — carried forward from the Slice-2 verified contract
  (A-4). A model typing them as `UUID` would fail to decode.
- `MatchResponse.ended_at` is `String?` and is the active/ended discriminator.
- The `zone` string written to `record.source = 'manual'` is one of the six
  values in §3.1; the client is the sole producer of that value (§2).

## 9. Non-Functional Requirements

### Configuration / secrets
- Reuses the Slice-2 injectable base URL (default `http://localhost:8080`) and
  Keychain-stored JWT. No new config, no secrets in code, no `.env` committed.

### Security
- Every gameplay route is called with `Authorization: Bearer <token>` from the
  Keychain-backed `TokenStore` (FR-M3, AC14). The client adds no new at-rest
  data beyond the existing token.
- The client sends only `source: "manual"` shots this slice; it never fabricates
  `cv` shots (CV is out of scope).

### Performance
- No latency target. Single-user volume; DESIGN.md notes a live `GROUP BY` over
  one match is already instant at this scale. The per-tap POST policy (OQ-3
  default) is acceptable at this volume.

### Known technical risk (carried from Slice 2)
- No iOS simulator runtime and a hand-authored `.xcodeproj`; the app target is
  **compile-only** (`xcodebuild build`). Simulator/UI tests remain deferred.
  This slice's real gate is `swift test` in TennisCore.

## 10. Verification Gates (verbatim)

- `swift test` in `ios/TennisCore` passes — **the real test gate**. 20+ new
  tests on top of the existing 52 (total 72+), all green.
- `xcodebuild build` of the app target succeeds (compile-only; no simulator).
- iOS simulator/UI tests + iOS CI job remain follow-ups.

## 11. Open Questions

Gate 1 is pre-approved, so each carries a recommended default that the coder
will follow unless the human overrides it.

- **OQ-1 — Zone boundary ownership.** *Answered in-spec (§4, FR-Z4):* the
  greater-coordinate side owns every dividing line (half-open intervals), so
  classification is total and deterministic. Listed here only for visibility;
  no action needed unless the human wants the opposite convention.
- **OQ-2 — Degenerate court rect.** If `rect.width <= 0` or `rect.height <= 0`
  the thirds/midline are undefined. **Default:** return `front_court_left`
  (the row-0/left-0 cell) as a safe deterministic fallback; the UI never passes
  a degenerate rect in practice. Confirm or choose a different fallback.
- **OQ-3 — Shot-recording flush policy.** Per tap: (a) POST one shot
  immediately (`addShots` with a single-element array), or (b) buffer locally
  and POST the batch on End Match. **Default: (a) per-tap POST.** In both cases
  the local shot list is **never dropped on a transport error** — a failed POST
  leaves the shot queued/marked for retry rather than lost. Confirm (a) vs (b),
  and whether failed per-tap POSTs retry automatically or on End Match.
- **OQ-4 — 404 handling on match-scoped routes.** The existing `mapError` has no
  `notFound` case; today a `404` (unknown match id) falls through to
  `else→server` (A-8). **Default:** leave `mapError` unchanged (surface it as a
  generic server error) to honor "follow APIClient style exactly." If a
  distinct "match not found" UX is wanted, adding a `notFound` case is a small,
  flagged change — confirm whether to make it now or defer.
- **OQ-5 — Match list ordering.** **Default: most-recent first** (by
  `created_at` descending; if the backend already returns a stable order, mirror
  it). Confirm, or specify grouping (e.g. active matches pinned to top).
- **OQ-6 — Are ended matches read-only?** **Default: yes** — tapping an ended
  match opens the summary only; no further shots can be added and there is no
  re-open action this slice (A-6). Confirm, or specify a re-open/edit path
  (would likely need a backend change, out of scope here).

## 12. Assumptions

Where the inputs are silent, these are the explicit assumptions so the coder has
no undocumented decision. Any of these the human can override.

- **A-1 — Six-value enum vs DESIGN.md taxonomy A.** DESIGN.md taxonomy A lists
  seven landing zones (adds `out_behind`, and frames `out_left/right` as *wide*
  outs). This Phase-1 client mirrors the **backend's six-value enum** (§3.1),
  which is the authority per the task. The geometric scheme makes `out_left/right`
  the *deep/beyond-baseline* cells and omits `out_behind`; reconciling the
  wide-out and `out_behind` semantics is deferred to v2 CV work. This divergence
  is intentional and does not block the slice.
- **A-2 — Equal-thirds depth split.** The two horizontal lines are at `1/3` and
  `2/3` of rect height (§4). DESIGN.md does not specify proportions; equal
  thirds is the simplest testable default. A non-uniform split (e.g. a smaller
  near-net band) is a one-constant change flagged here.
- **A-3 — MatchClient mirrors APIClient exactly.** Same injected
  `HTTPTransport` + `TokenStore`, same `buildRequest`/`mapError`/`.transport`
  machinery, same Bearer-header convention. Whether MatchClient is a sibling
  type or reuses the shared request builder is an implementation detail; the
  requirement is no divergent duplication (FR-M3).
- **A-4 — String, not UUID.** `id`/`user_id`/`match_id` decode to Swift
  `String`, consistent with the Slice-2 verified contract (`user_id` is a JSON
  string). Typing them as `UUID` would break decoding (AC1, AC3).
- **A-5 — Create sends only `court_surface`.** `location`, `played_at`,
  `video_ref` are left to backend defaults; the Phase-1 create flow collects
  only the surface. Adding those fields is deferred.
- **A-6 — No shot/match editing.** Recorded shots are not individually editable
  or deletable, a match's surface is not editable after creation, and ended
  matches are read-only (OQ-6). Editing is out of scope this slice.
- **A-7 — Timestamps decode as `String`.** `created_at`/`ended_at` are treated as
  opaque ISO-ish strings (display-formatted in the view layer) rather than
  decoded to `Date`, matching the "treat server values as-delivered" posture and
  avoiding a `JSONDecoder.dateDecodingStrategy` dependency on an unconfirmed
  server format. If `Date` decoding is preferred, the server timestamp format
  must be pinned first (flagged).
- **A-8 — `mapError` 404 gap left as-is.** The existing mapper has no
  `notFound`; `404` falls through to `else→server`. Kept to honor "follow
  APIClient style exactly" (OQ-4).
- **A-9 — ViewModels live in TennisCore.** Per the Slice-2 precedent (AC22: no
  testable logic in the app target), the three `@Observable` ViewModels are in
  TennisCore so they are `swift test`-able, and the SwiftUI views are thin
  readers. CLAUDE.md's `ios/.../ViewModels/` layout note is superseded by this
  testability constraint, consistent with Slice 2.
- **A-10 — StubTransport reused.** MatchClient tests use the existing hermetic
  `StubTransport` seam from Slice 2 (AC17); no new test transport is introduced.

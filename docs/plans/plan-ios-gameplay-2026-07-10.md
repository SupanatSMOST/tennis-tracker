# Plan: iOS App — Gameplay Screens (Phase 1, Slice 4)

**Spec:** `docs/specs/spec-ios-gameplay-2026-07-10.md` (Gate-1 approved)
**Date:** 2026-07-10
**Author:** architect (AI)
**Branch:** `feat/ios-gameplay` (already created, based on `feat/ios-auth-shell` — do NOT switch). All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Gate-1 resolutions baked in (the spec's OQ defaults are LOCKED — the coder does not re-open them):**
> - **OQ-1 (zone boundary ownership):** greater-coordinate side owns every dividing line (half-open intervals). `x == midX` → right; `y == h/3` → mid; `y == 2h/3` → deep (§4, FR-Z4).
> - **OQ-2 (degenerate rect):** `width <= 0` OR `height <= 0` → return `front_court_left` (the row-0 / left-0 cell) as a safe deterministic fallback. This has **no numbered AC** — it is pinned as an explicit ZoneClassifier test line (Task 3) so it is not lost.
> - **OQ-3 (flush policy):** **(a) per-tap POST** — each tap calls `addShots` with a single-element array immediately. On a `.transport` error the shot is **never dropped**: it stays in the local list marked `failed`. No automatic retry this slice (retry is a follow-up; the retention is the load-bearing requirement, AC24).
> - **OQ-4 (404 handling):** leave `mapError` UNCHANGED — a `404` falls through to `else → .server(404, message)`. Honors "follow APIClient style exactly" (A-8). No `notFound` case this slice.
> - **OQ-5 (match list ordering):** most-recent first (by `created_at` descending). If the backend already returns a stable order, mirror it; the VM sorts defensively on `created_at` descending.
> - **OQ-6 (ended matches read-only):** yes. Tapping an ended match opens the summary only; no re-open, no further shots, no edit (A-6).

---

## 0. Non-goals (carried forward from spec §3 "Out of scope")

Explicitly **not** built this slice:
- **No camera / AVFoundation / court framing / 4-corner homography** — deferred (Phase 2). The court diagram is a static schematic, not a camera overlay.
- **No CV / CoreML** — deferred (Phase 3). Zone comes from a human tap only; the client sends only `source: "manual"` shots.
- **No `out_behind` and no net-event zones** — not in the six-value Phase-1 enum (A-1). Deferred to v2.
- **No backend changes** — the seven routes (§4) are consumed as delivered on `feat/backend-gameplay-crud`.
- **No editing/deleting recorded shots**, no editing a match's surface, ended matches are read-only (A-6).
- **No Profile-tab work** — untouched from Slice 2 (Logout only).
- **No iOS simulator / UI tests / iOS CI job** — deferred (no simulator runtime; spec §9). Views are compile-only.
- **No new third-party dependency** — Foundation + CoreGraphics + Observation only (AC31).
- **No `Date` decoding** — timestamps stay opaque `String` (A-7); no `dateDecodingStrategy`.
- **No `location` / `played_at` / `video_ref` on create** — create sends only `court_surface` (A-5).

## 1. Architecture Overview

This slice adds the gameplay data path on top of the Slice-2 TennisCore foundation with **zero new dependencies** and **all logic in TennisCore** so it is provable by `swift test` (the real gate; `xcodebuild` is env-blocked, spec §9). The core insight is that the existing `APIClient`'s request machinery (`buildRequest` / `performSend` / `mapError`) is **`private`**, so a sibling `MatchClient` cannot reuse it. Rather than copy those four helpers verbatim (which A-3/FR-M3 forbids as "divergent duplication"), we **extract them once into an internal `RequestExecutor`** that owns `config` + `transport` + `tokenStore` and exposes the generic send/build/map machinery; `APIClient` is refactored to delegate to it (its public API and all 52 existing tests stay byte-for-byte green), and the new `MatchClient` is built on the same executor. This is the single load-bearing structural decision and it modifies a tested file — see §2.1 and Task 4.

On top of the client sit three `@Observable` ViewModels **in TennisCore** (per the Slice-2 AC22 precedent, superseding CLAUDE.md's `ios/.../ViewModels/` note — A-9), so the load-bearing shot-retention logic (AC24) is macOS-testable. A pure-CoreGraphics `ZoneClassifier` (no UIKit/SwiftUI) maps a tap point to one of exactly six zone strings. The app target gains four thin SwiftUI screens that only observe the VMs and call `ZoneClassifier` — they hold no networking, decoding, zone-mapping, or shot-list logic (AC30) — replacing the two Slice-2 placeholders and wiring the create → session → summary flow into the existing tab shell.

## 2. Component Design

### 2.1 iOS (Swift) — `ios/TennisCore` package

**New files:**
```
ios/TennisCore/Sources/TennisCore/
├── Models/
│   └── MatchModels.swift          # 6 Codable DTOs (FR-M1)
├── Networking/
│   └── RequestExecutor.swift      # NEW: shared request machinery extracted from APIClient
└── Gameplay/
    ├── MatchClient.swift          # 7 async methods (FR-M2/M3)
    ├── ZoneClassifier.swift       # pure-CoreGraphics classify(point:in:) (FR-Z1..Z5)
    ├── MatchListViewModel.swift    # @Observable (FR-VM1)
    ├── RecordSessionViewModel.swift# @Observable, shot retention (FR-VM2, AC24)
    └── MatchSummaryViewModel.swift # @Observable (FR-VM3)
```

**Modified files (tested — existing tests MUST stay green):**
- `ios/TennisCore/Sources/TennisCore/Networking/APIClient.swift` — refactor `buildRequest` / `performSend` / `mapError` / `EmptyBody` OUT into `RequestExecutor`; `APIClient` keeps its exact public API (`signup`/`login`/`fetchMe`, same signatures) and delegates internally. **Constraint:** all 52 existing tests (esp. `APIClientTests` AC5–AC19 + transport/noToken/server/malformed paths) stay green with no test edits.

**No new package dependencies** — `Package.swift` is untouched (AC31). CoreGraphics and Observation are system frameworks, not SPM deps.

**`Models/MatchModels.swift` (FR-M1).** Exactly six Codable DTOs. All UUID-bearing fields are Swift `String`, never `UUID` (a `UUID` field fails to decode — A-4). Snake-case JSON keys map via `CodingKeys` (mirror `AuthModels.swift`'s explicit-CodingKeys style; do NOT switch the whole codebase to `.convertFromSnakeCase`). Timestamps are opaque `String` (A-7).

```swift
public struct MatchResponse: Decodable {          // AC1, AC2
    public let id: String                          // JSON "id"        (String, not UUID — A-4)
    public let userId: String                      // JSON "user_id"
    public let courtSurface: String                // JSON "court_surface"
    public let createdAt: String                   // JSON "created_at" (opaque — A-7)
    public let endedAt: String?                    // JSON "ended_at"   (null → nil; active/ended discriminator)
}
public struct ShotResponse: Decodable {           // AC3
    public let id: String                          // "id"
    public let matchId: String                     // "match_id"
    public let zone: String                        // one of the six §3.1 strings
    public let source: String                      // "manual" this slice
    public let createdAt: String                   // "created_at"
}
public struct SummaryEntry: Decodable {           // AC4
    public let matchId: String                     // "match_id"
    public let zone: String
    public let count: Int                          // Int
}
public struct CreateMatchRequest: Encodable {     // AC5 → {"court_surface":"..."}
    public let courtSurface: String                // CodingKeys: courtSurface = "court_surface"
}
public struct ShotInput: Encodable {              // AC6 element
    public let zone: String
    public let source: String                      // MUST hold "manual" as a stored value so it ENCODES
    public init(zone: String, source: String = "manual") { self.zone = zone; self.source = source }
}
public struct AddShotsRequest: Encodable {        // AC6 → {"shots":[...]}
    public let shots: [ShotInput]
}
```

> **ShotInput default (AC6 flag):** a Swift default *init parameter* does not auto-encode — the `source` **property** must actually hold `"manual"` so the key appears in the JSON. The `init(... source: String = "manual")` default sets the stored property; it does not skip encoding.

The `POST /matches/{id}/shots` response `{"count":N}` has **no named DTO** — it is decoded by a **private nested type inside MatchClient** and `addShots` returns the `Int` count. The six DTOs above are the complete public set (FR-M2); this inline decode is not a 7th DTO.

**`Networking/RequestExecutor.swift` (NEW — the load-bearing structural extraction).** An `internal` type holding the three injected seams and the request machinery lifted verbatim from `APIClient`'s current private helpers, so no logic diverges (A-3/FR-M3):

```swift
final class RequestExecutor {                      // internal to TennisCore
    let config: APIConfig
    let transport: HTTPTransport
    let tokenStore: TokenStore
    init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore)

    // Lifted 1:1 from APIClient (same behavior, same error wrapping):
    func buildRequest<Body: Encodable>(method: String, path: String, body: Body?) throws -> URLRequest
    func performSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)  // wraps thrown → .transport
    func mapError(data: Data, status: Int) throws -> APIError                        // 400/401/409/else exactly as today
    func authorizedRequest<Body: Encodable>(method: String, path: String, body: Body?) throws -> URLRequest
        // convenience: buildRequest + set "Authorization: Bearer <tokenStore.get()>"; throws .noToken if absent
}
```

- `mapError` is unchanged (400→validation, 401→invalidCredentials, 409→usernameTaken, else→server). 404 falls through to `.server(404, msg)` — OQ-4/A-8, no `notFound` case.
- `performSend` wraps a thrown transport error as `.transport(error)` BEFORE any status mapping — the exact ordering `APIClient` relies on (so status-mapping throws are never mis-wrapped as `.transport`).
- The `EmptyBody` sentinel for body-less requests moves here (or MatchClient reuses `nil as EmptyBody?`); keep one definition. **`EmptyBody` MUST be `internal`, not `private`** — the four `MatchClient` GET methods call `authorizedRequest(..., body: nil as EmptyBody?)`, so a `private` `EmptyBody` would not compile from `MatchClient`.

> **Success-status guard policy (pinned — this is an architect decision, not the coder's).** Spec §6 lists success *bodies* but not status codes, so the three POST codes are ambiguous (201 vs 200). **Policy: treat any `2xx` as success across all seven methods** (`(200...299).contains(response.statusCode)`), then decode; non-2xx → `executor.mapError`. This is robust to the unpinned POST codes and does not violate A-3 — "follow APIClient style exactly" governs the request machinery and the error mapping (which are unchanged), not the guard granularity. `APIClient`'s own exact-code guards (201 signup / 200 login) are left as-is; the 2xx-range guard applies only to the new `MatchClient` methods.

`APIClient` after refactor: constructs/holds a `RequestExecutor` and delegates; its `persistToken` and the three public methods keep identical externally-observable behavior. **Verification:** `APIClientTests` (unchanged) stays green — that is the refactor's acceptance bar.

**`Gameplay/MatchClient.swift` (FR-M2/M3, AC7–AC17).** A peer type to `APIClient`, same init shape, built on the shared `RequestExecutor`:

```swift
public final class MatchClient {
    public init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore)
    public func createMatch(surface: String) async throws -> MatchResponse            // POST /matches            (AC7)
    public func listMatches() async throws -> [MatchResponse]                          // GET  /matches            (AC8)
    public func getMatch(id: String) async throws -> MatchResponse                     // GET  /matches/{id}       (AC9)
    public func endMatch(id: String) async throws -> MatchResponse                     // POST /matches/{id}/end   (AC10)
    public func addShots(matchID: String, shots: [ShotInput]) async throws -> Int      // POST /matches/{id}/shots (AC11)
    public func listShots(matchID: String) async throws -> [ShotResponse]              // GET  /matches/{id}/shots (AC12)
    public func getSummary(matchID: String) async throws -> [SummaryEntry]             // GET  /matches/{id}/summary(AC13)
}
```

- Every method builds via `executor.authorizedRequest` → `Authorization: Bearer <token>` from the injected `TokenStore` (AC14). Path interpolation uses the `id`/`matchID` string.
- Success-status guard (**any `2xx`** — see policy above) then `JSONDecoder().decode(...)` into the return type; non-2xx → `executor.mapError` throw (401→invalidCredentials, 400→validation — AC15). Transport throw → `.transport` (AC16), distinct from an HTTP status.
- `addShots` posts `AddShotsRequest(shots:)` and decodes `{"count":N}` via a `private struct CountResponse: Decodable { let count: Int }`, returning `.count` (AC11). The `count` equals the number of shots sent when the backend echoes them.
- Whether `MatchClient` is a sibling type or a thin wrapper is an implementation detail; the invariant is **no divergent duplication of the request machinery** — it MUST route through `RequestExecutor`.

**`Gameplay/ZoneClassifier.swift` (FR-Z1..Z5, AC18–AC23).** Pure CoreGraphics; imports **`CoreGraphics` only** (for `CGPoint`/`CGRect` — available under macOS `swift test`); **MUST NOT import UIKit or SwiftUI** (else `swift test` on macOS breaks).

```swift
import CoreGraphics
public enum ZoneClassifier {
    public static func classify(point: CGPoint, in rect: CGRect) -> String
}
```

Algorithm (pinned, no coder discretion — §4 of spec):
1. **Degenerate guard (OQ-2):** if `rect.width <= 0 || rect.height <= 0` → return `"front_court_left"`.
2. **Clamp (FR-Z5, AC22):** `x = min(max(point.x, rect.minX), rect.maxX)`; `y = min(max(point.y, rect.minY), rect.maxY)`.
3. **Column (FR-Z2/Z4, AC19):** `x < rect.midX` → left; `x >= rect.midX` → right (midline right-owned).
4. **Row (FR-Z2/Z4, AC20):** `h = rect.height`; `y < minY + h/3` → near-net; `y < minY + 2h/3` → mid; else → deep (each boundary greater-coordinate-owned via `<`).
5. **Map (FR-Z3, AC18/AC21):** `(near-net,left)→front_court_left`, `(near-net,right)→front_court_right`, `(mid,left)→baseline_left`, `(mid,right)→baseline_right`, `(deep,left)→out_left`, `(deep,right)→out_right`.

Returns exactly one of the six §3.1 strings for any finite input (AC23) — non-optional, no "unknown".

**`Gameplay/MatchListViewModel.swift` (FR-VM1, AC26).** `@Observable`, injected `MatchClient`.
- Holds `matches: [MatchResponse]`, `loadError: String?` (or an `APIError?`), and a loading flag.
- `load()` calls `listMatches()`, sorts **most-recent-first by `createdAt` descending** (OQ-5), stores; on error stores the surfaced message (no crash).
- `create(surface:)` calls `createMatch(surface:)`, returns/exposes the new `MatchResponse` so the view can route into its `RecordSessionView`; surfaces create errors.
- **Routing classifier (AC26):** a pure helper `isActive(_ m: MatchResponse) -> Bool { m.endedAt == nil }` — active routes to session, ended routes to summary (FR-V2). This is the testable routing seam; the view merely reads it.

**`Gameplay/RecordSessionViewModel.swift` (FR-VM2, AC24/AC25 — load-bearing).** `@Observable`, injected `MatchClient`, holds the active match `id`.

```swift
public enum ShotStatus { case pending, confirmed, failed }        // per-shot lifecycle
public struct LocalShot: Identifiable {                            // value type; local ordered list element
    public let id: UUID                                            // client-side id for list identity
    public let zone: String
    public var status: ShotStatus
}
```

- `shots: [LocalShot]` is the **local ordered list**, appended on each tap in tap order.
- `record(zone:)` (per-tap, OQ-3 option a): **append a `LocalShot(status: .pending)` FIRST**, then `await addShots(matchID:shots:[ShotInput(zone:)])`; on success mark that element `.confirmed`; on `catch APIError.transport` (or any thrown error) mark it `.failed` but **leave it in the array** — it is NEVER removed (AC24). No auto-retry this slice.
- `count: Int { shots.count }` — the running counter reflects every tapped shot including failed ones (AC24/AC25). Expose `lastN` (a suffix slice) for display.
- `endMatch()` calls `endMatch(id:)` with the active match id and exposes the returned (ended) `MatchResponse` so the view can route to summary (AC25).

> **AC24 shape (pinned so coder and test-writer do not diverge):** the retention model is exactly "append-before-POST + mark-status-on-result, never-remove." `count` derives from `shots.count`. A `.transport` throw leaves the element present with `status == .failed`; the count is unchanged from the moment of tap. This makes AC24 (never-dropped) and AC25 (order + count) mechanically testable via `StubTransport`.

**`Gameplay/MatchSummaryViewModel.swift` (FR-VM3, AC27).** `@Observable`, injected `MatchClient`, holds the match `id`.
- `entries: [SummaryEntry]`, `loadError: String?`.
- `load()` calls `getSummary(matchID:)`, stores the per-zone counts for display; a stubbed/thrown error surfaces as `loadError` (no crash).

> **`@Observable` fallback (carried from Slice 2):** if the Observation macro fights the toolchain, keep pure transition logic in a plain testable type behind a thin `@Observable` wrapper. Try direct `@Observable` first — Slice 2 proved it builds on this host.

### 2.2 iOS (Swift) — `TennisShotTracker` app target (thin, build-only)

**New files:**
```
ios/TennisShotTracker/TennisShotTracker/Views/
├── MatchListView.swift      # Home tab: match list + create FAB (FR-V1/V2)
├── CreateMatchSheet.swift    # surface picker → create → route to session (FR-V3)
├── RecordSessionView.swift   # court diagram, tap → ZoneClassifier → VM.record (FR-V4)
└── MatchSummaryView.swift    # per-zone counts bar/grid (FR-V5)
```

**Modified files:**
- `ios/TennisShotTracker/TennisShotTracker/Views/TabShellView.swift` — replace `HomePlaceholderView()` with `MatchListView(...)` and `RecordPlaceholderView()` with the record-flow entry (AC29). Profile tab unchanged.
- `ios/TennisShotTracker/TennisShotTracker/TennisShotTrackerApp.swift` — construct a `MatchClient` from the SAME `APIConfig` / `URLSessionTransport` / `KeychainTokenStore` used to build `APIClient` (mirror the existing init), and inject it into the gameplay views/VMs. No new logic — just wiring.
- `ios/TennisShotTracker/TennisShotTracker/Views/HomePlaceholderView.swift`, `RecordPlaceholderView.swift` — **deleted** (superseded, AC29). Remove from the pbxproj build phase.
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add the four new view files to the app-target build phase; remove the two deleted placeholders.

**View responsibilities (all thin — AC30: no networking/decoding/zone-mapping/shot-list logic in the app target):**
- **`MatchListView` (FR-V1/V2):** observes `MatchListViewModel`; lists matches with a court-surface badge + a date (the raw `createdAt` string, display-formatted in-view only); most-recent-first per the VM's ordering. A toolbar `+` (or FAB) presents `CreateMatchSheet`. Tapping a match routes by `viewModel.isActive(match)`: active → `RecordSessionView`; ended → `MatchSummaryView`.
- **`CreateMatchSheet` (FR-V3):** a surface picker (hard / clay / grass), a confirm action calling `viewModel.create(surface:)`, then routes into the new match's `RecordSessionView`.
- **`RecordSessionView` (FR-V4):** draws the static six-zone court diagram (net at top, baseline at bottom); makes **only the court rect** tappable; on each tap reads the tap location + the diagram rect (e.g. via a `GeometryReader`/`.coordinateSpace`) and calls `ZoneClassifier.classify(point:in:)`, passing the resulting zone to `viewModel.record(zone:)`. Shows the live shot counter (`viewModel.count`), the last-N shots, and an End Match button that calls `viewModel.endMatch()` and routes to summary on success. **No zone math in the view** beyond calling `ZoneClassifier` (AC30).
- **`MatchSummaryView` (FR-V5):** renders `MatchSummaryViewModel.entries` as a bar or grid keyed by zone.

### 2.3 CV Pipeline (Python)
**N/A** — explicit non-goal (§3). Zone comes from a human tap; no CV/CoreML this slice.

### 2.4 Backend (Go)
**N/A** — the seven routes (§4) are consumed as delivered on `feat/backend-gameplay-crud`; no server work.

## 3. Data Model Changes

**None.** No database and no schema change (spec §8). The client consumes the API only. Load-bearing client-side data facts:
- All UUID-bearing fields (`id`, `user_id`, `match_id`) decode to Swift `String`, never `UUID` (A-4) — a `UUID` model fails to decode (AC1, AC3).
- `MatchResponse.endedAt` is `String?` and is the active/ended discriminator (AC2, AC26).
- The `zone` written to a `manual` shot is one of the six §3.1 strings; the client is the sole producer (§2 of spec).

## 4. API Contract (consumed as delivered on `feat/backend-gameplay-crud`)

All routes require `Authorization: Bearer <token>`. Bodies are JSON. `id`, `user_id`, `match_id` are JSON **strings**; timestamps are JSON strings; `ended_at` may be `null`. Error shape is the uniform `{"error":"<message>"}`; status mapping reuses the existing `mapError` (400→validation, 401→invalidCredentials, 409→usernameTaken, else→server; **404 falls through to server** — OQ-4/A-8).

| # | Method & path | Request body | Success body | Client method |
|---|---|---|---|---|
| 1 | `POST /matches` | `{"court_surface":"hard"\|"clay"\|"grass"}` | `MatchResponse` | `createMatch` |
| 2 | `GET /matches` | — | `[ MatchResponse ]` | `listMatches` |
| 3 | `GET /matches/{id}` | — | `MatchResponse` | `getMatch` |
| 4 | `POST /matches/{id}/end` | — | `MatchResponse` (`ended_at` set) | `endMatch` |
| 5 | `POST /matches/{id}/shots` | `{"shots":[{"zone":"…","source":"manual"},…]}` | `{"count":N}` | `addShots` → `Int` |
| 6 | `GET /matches/{id}/shots` | — | `[ ShotResponse ]` | `listShots` |
| 7 | `GET /matches/{id}/summary` | — | `[ SummaryEntry ]` | `getSummary` |

## 5. Sequence Diagrams (text)

**Create → record → end → summary (the full manual data path):**
1. Home tab shows `MatchListView` observing `MatchListViewModel.load()` → `GET /matches` (AC8), sorted most-recent-first (OQ-5).
2. User taps `+` → `CreateMatchSheet`; picks a surface; confirm → `MatchListViewModel.create(surface:)` → `POST /matches` (AC7) → new `MatchResponse`.
3. App routes into `RecordSessionView(matchID: new.id)` with a `RecordSessionViewModel`.
4. Each tap on the court rect → `ZoneClassifier.classify(point:in:)` → zone string → `viewModel.record(zone:)`:
   a. append `LocalShot(.pending)` (count increments — AC25).
   b. `POST /matches/{id}/shots` with one `ShotInput` (AC11).
   c. 2xx → mark `.confirmed`; **transport error → mark `.failed`, keep in list** (AC24).
5. User taps End Match → `viewModel.endMatch()` → `POST /matches/{id}/end` (AC10) → ended `MatchResponse`.
6. App routes to `MatchSummaryView` → `MatchSummaryViewModel.load()` → `GET /matches/{id}/summary` (AC13) → per-zone counts (AC27).

**Open an existing match from the list (FR-V2, AC26):**
1. `MatchListViewModel.isActive(m)` = `m.endedAt == nil`.
2. active → `RecordSessionView`; ended → `MatchSummaryView` (read-only, OQ-6).

**Auth header on every call (AC14):**
1. `MatchClient` method → `executor.authorizedRequest` reads `tokenStore.get()`.
2. Sets `Authorization: Bearer <token>`; no token → `.noToken` (mirrors `APIClient.fetchMe`).

## 6. AC → Design coverage matrix

| AC | Satisfied by | Where |
|---|---|---|
| AC1 | `MatchResponse` String ids + `endedAt: String?` decodes null→nil | MatchModels |
| AC2 | non-null `ended_at` → non-nil; VM active/ended discriminator | MatchModels / MatchListVM |
| AC3 | `ShotResponse` String ids | MatchModels |
| AC4 | `SummaryEntry` `count: Int` | MatchModels |
| AC5 | `CreateMatchRequest` → `{"court_surface":...}` | MatchModels |
| AC6 | `AddShotsRequest` + `ShotInput` (source stored = "manual") | MatchModels |
| AC7 | `createMatch` POST /matches + Bearer + parse | MatchClient |
| AC8 | `listMatches` GET /matches → array | MatchClient |
| AC9 | `getMatch` GET /matches/{id} | MatchClient |
| AC10 | `endMatch` POST /matches/{id}/end → non-nil endedAt | MatchClient |
| AC11 | `addShots` POST → inline `{count}` decode → Int | MatchClient |
| AC12 | `listShots` GET /matches/{id}/shots → array | MatchClient |
| AC13 | `getSummary` GET /matches/{id}/summary → array | MatchClient |
| AC14 | Bearer header on all 7 via `executor.authorizedRequest` | RequestExecutor / MatchClient |
| AC15 | 401→invalidCredentials, 400→validation via shared `mapError` | RequestExecutor |
| AC16 | transport throw → `.transport` via shared `performSend` | RequestExecutor |
| AC17 | all MatchClient tests use injected `StubTransport` | tests |
| AC18 | six cell centers → six strings | ZoneClassifier |
| AC19 | midX right-owned | ZoneClassifier |
| AC20 | h/3 → mid, 2h/3 → deep (greater-coordinate-owned) | ZoneClassifier |
| AC21 | four corners deterministic | ZoneClassifier |
| AC22 | out-of-rect clamps → valid zone | ZoneClassifier |
| AC23 | grid sweep never returns non-enum string | ZoneClassifier |
| AC24 | append-before-POST, mark-failed-never-drop, count = shots.count | RecordSessionVM |
| AC25 | N taps → N ordered shots; endMatch calls client | RecordSessionVM |
| AC26 | `isActive = endedAt == nil` routing | MatchListVM |
| AC27 | `getSummary` load + error surface | MatchSummaryVM |
| AC28 | `xcodebuild build` (env-permitting; else iOS type-check compensator per Slice-2 precedent) | app target |
| AC29 | placeholders deleted; MatchListView/RecordSessionView wired into TabShell | TabShellView / views |
| AC30 | inspection: no logic in app target | app-target views |
| AC31 | Package.swift + app target add no new dep | Package.swift (untouched) |

Plus (Gate-1, no numbered AC): **OQ-2 degenerate-rect fallback** — `front_court_left`, pinned as an explicit ZoneClassifier test (Task 3).

## 7. Risks & Mitigations

- **Private APIClient helpers block reuse (the central risk).** `buildRequest`/`performSend`/`mapError`/`EmptyBody` are `private`; a sibling `MatchClient` can't call them, and copy-paste violates A-3. Mitigation: extract `RequestExecutor` once (§2.1, Task 4) and delegate from both clients. This modifies a tested file — the acceptance bar is that all 52 existing tests stay green with NO test edits.
- **Refactoring APIClient could regress auth (52 green tests).** Keep `APIClient`'s public API and externally-observable behavior byte-identical; move logic, don't change it. `mapError` ordering and the `performSend` transport-wrap-before-status-map invariant are load-bearing — preserve exactly.
- **AC24 vagueness ("queued/marked-failed").** Pinned to a concrete `LocalShot`+`ShotStatus` shape with append-before-POST semantics (§2.1) so coder and test-writer converge.
- **`ShotInput.source` not encoding.** The `source` property must hold `"manual"` (stored value), not just a default init param — else the key is absent from the JSON (AC6).
- **ZoneClassifier reaching for UIKit.** `CGPoint`/`CGRect` are in CoreGraphics — import CoreGraphics only; UIKit/SwiftUI would break macOS `swift test` (FR-Z1).
- **Degenerate rect has no numbered AC.** Pinned as an explicit test line (Task 3) so OQ-2's `front_court_left` fallback isn't dropped.
- **`xcodebuild build` env-blocked (spec §9, carried from Slice 2).** The real gate is `swift test`. If the iOS platform destination is unresolvable as in Slice 2, fall back to the `swiftc -typecheck` iOS-SDK compensator over the app-target sources; record the deviation for Gate 2. Do not let a build-env failure block the green TennisCore work.
- **Test count must clear 20+ new / 72+ total.** Budget: 6 DTO + ~11 MatchClient (7 methods + Bearer + 401/400 + transport) + 6 ZoneClassifier + 4 VM ≈ 27 new tests → 79+ total. Demonstrated in the task acceptance criteria.
- **`@Observable` toolchain risk.** Slice 2 proved it builds; fallback is a plain type behind a thin wrapper (§2.1).

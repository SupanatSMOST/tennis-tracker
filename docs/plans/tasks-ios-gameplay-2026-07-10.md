# Tasks: iOS App — Gameplay Screens (Phase 1, Slice 4)

**Plan:** `docs/plans/plan-ios-gameplay-2026-07-10.md`
**Spec:** `docs/specs/spec-ios-gameplay-2026-07-10.md` (Gate-1 approved)
**Total tasks:** 9
**Branch:** `feat/ios-gameplay` (already created, based on `feat/ios-auth-shell` — do NOT switch). All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Order (dependency-driven, per the sequencing guidance):** DTOs → ZoneClassifier (pure, no deps) → RequestExecutor extraction + MatchClient → the three ViewModels → SwiftUI views (build-only) → final gate. Tasks 1–7 make `swift test` green — the real gate (spec §10). The `RequestExecutor` extraction (Task 3) lands before `MatchClient` because MatchClient is built on it AND it refactors a tested file that must stay green. Views (Task 8) come last and are build-only.
>
> **Conventions:** SwiftUI + MVVM; ViewModels `@Observable` and IN TennisCore (A-9, superseding CLAUDE.md's ViewModels-folder note); async/await for all I/O (no completion handlers); **XCTest** (not swift-testing); conventional commits. `id`/`user_id`/`match_id` are JSON STRINGS → Swift `String`, never `UUID`. Timestamps are opaque `String` (A-7). No third-party deps (AC31). The six zone strings are EXACTLY `front_court_left`, `front_court_right`, `baseline_left`, `baseline_right`, `out_left`, `out_right` (§3.1) — byte-for-byte, no `out_behind`. Each task is one coder pass (≤ ~200 lines new code). Migrations rule (never combine migration + app code) is N/A — no migrations this slice.
>
> **The seven backend routes and the six OQ defaults are LOCKED (plan §0 header). The coder does NOT re-open them.**

---

## Task 1: Match DTOs (Models/MatchModels.swift) + decoding/encoding tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Models/MatchModels.swift` — the six Codable DTOs exactly per plan §2.1: `MatchResponse` (`id`,`userId`,`courtSurface`,`createdAt` as `String`; `endedAt` as `String?`), `ShotResponse` (`id`,`matchId`,`zone`,`source`,`createdAt` all `String`), `SummaryEntry` (`matchId`,`zone` `String`; `count` `Int`), `CreateMatchRequest` (`courtSurface`→`"court_surface"`), `ShotInput` (`zone`,`source`; `init(zone:source:String="manual")` sets the STORED `source` so it encodes), `AddShotsRequest` (`shots:[ShotInput]`). Snake-case JSON via explicit `CodingKeys` (mirror `AuthModels.swift`; do NOT switch to `.convertFromSnakeCase`). All UUID-bearing fields are `String`, never `UUID`.
- `ios/TennisCore/Tests/TennisCoreTests/MatchModelDecodingTests.swift` — canned-JSON decode/encode fixtures.
**Depends on:** none (TennisCore package already exists from Slice 2)
**Acceptance (AC1–AC6):** `MatchResponse` decodes `ended_at:null` → `nil` (AC1) and a non-null `ended_at` string → non-nil (AC2), all ids as `String`; `ShotResponse` (AC3) and `SummaryEntry` with `count:Int` (AC4) decode; `CreateMatchRequest` encodes to exactly `{"court_surface":"clay"}` (AC5); `AddShotsRequest([ShotInput(zone:"front_court_left"), ShotInput(zone:"out_right")])` encodes to `{"shots":[{"zone":"front_court_left","source":"manual"},{"zone":"out_right","source":"manual"}]}` (AC6, order-independent shape, `source` present).
**Test:** `swift test`: decode the AC1/AC2/AC3/AC4 fixtures (assert `endedAt` nil vs non-nil, ids are `String`, `count` is `Int`); encode `CreateMatchRequest(courtSurface:"clay")` and assert the key is `court_surface` with no extra fields; encode a two-element `AddShotsRequest` and assert each element carries `zone` AND `source:"manual"` (the source-must-encode guard). A fixture with a non-UUID string `id` decodes fine (guards a `UUID` regression).

## Task 2: ZoneClassifier (pure CoreGraphics) + geometry tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Gameplay/ZoneClassifier.swift` — `import CoreGraphics` ONLY (no UIKit/SwiftUI). `public enum ZoneClassifier { public static func classify(point: CGPoint, in rect: CGRect) -> String }`. Algorithm exactly per plan §2.1: (1) degenerate guard `width<=0||height<=0` → `"front_court_left"`; (2) clamp `x`/`y` into rect bounds; (3) column `x < midX` left / `x >= midX` right; (4) rows by `minY+h/3`, `minY+2h/3` using `<` (greater-coordinate side owns the line); (5) map the 2×3 cell to the six §3.1 strings.
- `ios/TennisCore/Tests/TennisCoreTests/ZoneClassifierTests.swift`.
**Depends on:** none (pure; no DTOs, no client)
**Acceptance (AC18–AC23 + OQ-2):** on `CGRect(0,0,120,120)` the six cell centers map 1:1 per §4 (AC18); `x==midX` → right column (AC19); `y==h/3` → mid row, `y==2h/3` → deep row (AC20); the four corners resolve top-left→`front_court_left`, top-right→`front_court_right`, bottom-left→`out_left`, bottom-right→`out_right` (AC21); an out-of-rect point clamps to a valid zone — left/above → `front_court_left`, right/below → `out_right` (AC22); a grid sweep of sample points never returns a string outside the six-value set (AC23); a degenerate rect (`width<=0` or `height<=0`) returns `front_court_left` (OQ-2 — explicit test line, no numbered AC).
**Test:** `swift test`: the six centers (AC18); `(60,20)→front_court_right` (AC19); `(30,40)→baseline_left`, `(30,80)→out_left` (AC20); four corners (AC21); a point at `(-10,-10)→front_court_left` and `(999,999)→out_right` (AC22); a nested loop over a grid asserting membership in the six-set (AC23); `classify(_, in: CGRect(0,0,0,120))` and `(0,0,120,0)` → `front_court_left` (OQ-2).

## Task 3: Extract RequestExecutor from APIClient (refactor tested file; keep 52 tests green)
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Networking/RequestExecutor.swift` — NEW `internal final class RequestExecutor` holding `config`/`transport`/`tokenStore`, exposing `buildRequest(method:path:body:)`, `performSend(_:)` (wraps a thrown transport error as `.transport` BEFORE any status mapping), `mapError(data:status:)` (400→validation, 401→invalidCredentials, 409→usernameTaken, else→server — UNCHANGED; 404 falls through to server per OQ-4/A-8), and `authorizedRequest(method:path:body:)` (= buildRequest + `Authorization: Bearer <tokenStore.get()>`; throws `.noToken` if absent). Move the `EmptyBody` sentinel here (single definition) as **`internal`, NOT `private`** — MatchClient's GET methods call `authorizedRequest(..., body: nil as EmptyBody?)` and a `private` sentinel would not compile from MatchClient. All logic lifted 1:1 from the current `APIClient` private helpers — no behavior change.
- `ios/TennisCore/Sources/TennisCore/Networking/APIClient.swift` — MODIFY: hold a `RequestExecutor` and delegate `signup`/`login`/`fetchMe` through it; keep the exact public API and externally-observable behavior (shared `persistToken` path, Bearer header on `fetchMe`, `.noToken` when unauth). Remove the now-duplicated private helpers.
**Depends on:** none (independent of Tasks 1/2; sequenced here so MatchClient in Task 4 can build on it)
**Acceptance:** `RequestExecutor` owns the request machinery with no divergent copy (FR-M3/A-3). **All 52 existing TennisCore tests stay green with NO edits to any test file** — this is the refactor's acceptance bar (esp. `APIClientTests` AC5–AC19 + the transport/noToken/server/malformed paths). `mapError` cases and the "transport-wrap-before-status-map" ordering are byte-identical to before.
**Test:** `swift test`: the UNCHANGED `APIClientTests`, `ModelDecodingTests`, `SessionStoreTests`, etc. all pass (52 green). No new test file required for this task; the guarantee is "no regression." (Optionally add one `RequestExecutorTests` asserting `authorizedRequest` sets the Bearer header and throws `.noToken` on an empty store — counts toward the new-test tally.)

## Task 4: MatchClient (7 async methods) + StubTransport-backed tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Gameplay/MatchClient.swift` — `public final class MatchClient`, `init(config:transport:tokenStore:)` (mirrors `APIClient`; constructs a `RequestExecutor`). Seven `async throws` methods per plan §2.1/§4: `createMatch(surface:)→MatchResponse` (POST /matches, body `CreateMatchRequest`), `listMatches()→[MatchResponse]`, `getMatch(id:)→MatchResponse`, `endMatch(id:)→MatchResponse` (POST /matches/{id}/end), `addShots(matchID:shots:)→Int` (POST /matches/{id}/shots, body `AddShotsRequest`; decode `{"count":N}` via a `private struct CountResponse: Decodable { let count: Int }`, return `.count`), `listShots(matchID:)→[ShotResponse]`, `getSummary(matchID:)→[SummaryEntry]`. Every method builds via `executor.authorizedRequest` (Bearer header), guards the success status as **any `2xx`** (`(200...299).contains(response.statusCode)` — POST codes are unpinned in §6; this policy is fixed in plan §2.1, NOT the coder's choice), decodes, and maps non-2xx via `executor.mapError`. No completion handlers.
- `ios/TennisCore/Tests/TennisCoreTests/MatchClientTests.swift` — reuse the existing `StubTransport` (`.make(status:body:)` / `.throwing(_)`) and `InMemoryTokenStore`. Hermetic — no live backend (AC17).
**Depends on:** Task 1 (DTOs), Task 3 (RequestExecutor)
**Acceptance (AC7–AC17):** each method issues the right method+path and parses the right type — `createMatch` posts `{"court_surface":...}` + parses `MatchResponse` (AC7); `listMatches` → `[MatchResponse]` (AC8); `getMatch` (AC9); `endMatch` → non-nil `endedAt` (AC10); `addShots` posts `{"shots":[...]}` → `Int` count == shots sent (AC11); `listShots` → `[ShotResponse]` (AC12); `getSummary` → `[SummaryEntry]` (AC13); all seven send `Authorization: Bearer <token>` from the injected `TokenStore` (AC14); a `401` → `.invalidCredentials`, a `400` → `.validation` via the shared `mapError` (AC15); a thrown transport failure → `.transport`, distinct from an HTTP status (AC16); every test passes with `localhost:8080` unreachable (AC17).
**Test:** `swift test` with `StubTransport` + `InMemoryTokenStore`: capture the outgoing `URLRequest` per method and assert the HTTP method, path suffix, and `Authorization: Bearer <token>` header (AC14); assert the decoded return value for each canned success body (AC7–AC13); stub a 401 and a 400 and assert the mapped `APIError` case (AC15); stub `.throwing` and assert `.transport` (AC16). Assert `addShots` returns the count from `{"count":N}` (AC11).

## Task 5: MatchListViewModel + MatchSummaryViewModel (@Observable) + tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Gameplay/MatchListViewModel.swift` — `@Observable`, `init(client: MatchClient)`. Holds `matches:[MatchResponse]`, `loadError`. `load()` → `listMatches()`, sort most-recent-first by `createdAt` descending (OQ-5), store; on error store the message (no crash). `create(surface:)` → `createMatch(surface:)`, expose the new `MatchResponse`; surface create errors. Pure routing helper `isActive(_ m: MatchResponse) -> Bool { m.endedAt == nil }` (AC26).
- `ios/TennisCore/Sources/TennisCore/Gameplay/MatchSummaryViewModel.swift` — `@Observable`, `init(client: MatchClient, matchID: String)`. Holds `entries:[SummaryEntry]`, `loadError`. `load()` → `getSummary(matchID:)`, store; a thrown error → `loadError` (no crash) (AC27).
- `ios/TennisCore/Tests/TennisCoreTests/MatchListViewModelTests.swift`, `ios/TennisCore/Tests/TennisCoreTests/MatchSummaryViewModelTests.swift`.
**Depends on:** Task 4 (MatchClient)
**Acceptance (AC26, AC27):** a `MatchResponse` with `endedAt==nil` → `isActive` true (routes to session); non-nil `endedAt` → `isActive` false (routes to summary) (AC26). `MatchSummaryViewModel.load()` with a stubbed summary exposes the per-zone counts; a stubbed error surfaces as `loadError`, not a crash (AC27). `load()` sorts matches most-recent-first (OQ-5). All hermetic via `StubTransport`.
**Test:** `swift test`: build each VM with a `MatchClient` over `StubTransport`; (AC26) feed two matches (one `ended_at:null`, one set) and assert `isActive` per match + list load/sort order; (AC27) stub a summary array → assert `entries`; stub `.throwing` → assert `loadError` set and no crash.

## Task 6: RecordSessionViewModel (@Observable) — shot retention (load-bearing) + tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Gameplay/RecordSessionViewModel.swift` — `@Observable`, `init(client: MatchClient, matchID: String)`. Types `enum ShotStatus { case pending, confirmed, failed }` and `struct LocalShot: Identifiable { let id: UUID; let zone: String; var status: ShotStatus }`. Holds `shots:[LocalShot]`. `record(zone:)` per OQ-3 option (a): APPEND `LocalShot(id:UUID(),zone:,status:.pending)` FIRST, then `await addShots(matchID:shots:[ShotInput(zone:)])`; on success mark that element `.confirmed`; on `catch` (transport or any thrown error) mark it `.failed` but **NEVER remove it** (AC24). `var count: Int { shots.count }`; expose `lastN` suffix for display. `endMatch()` → `endMatch(id: matchID)`, expose the returned ended `MatchResponse` (AC25). No auto-retry this slice.
- `ios/TennisCore/Tests/TennisCoreTests/RecordSessionViewModelTests.swift`.
**Depends on:** Task 4 (MatchClient)
**Acceptance (AC24, AC25 — load-bearing):** with `addShots` stubbed to THROW `.transport`, `record(zone:)` leaves the shot in `shots` marked `.failed` and `count` still counts it — a shot is NEVER silently dropped on a network blip (AC24). Happy path: N `record` calls append N shots in tap order, `count == N`, each `.confirmed`; `endMatch()` calls `endMatch(id:)` with the active match id (AC25).
**Test:** `swift test`: (AC24) `StubTransport.throwing(...)` → `await record(zone:"baseline_left")` → assert `shots.count == 1`, `shots[0].status == .failed`, `count == 1` (not dropped); (AC25) `StubTransport.make(200, {"count":1})` → `record` N zones in order → assert `shots.map(\.zone)` equals the tapped order, `count == N`, all `.confirmed`; stub `endMatch` and assert it is called with the correct `matchID` and the returned match is exposed.

> **GATE CHECKPOINT:** after Task 6, `cd ios/TennisCore && swift test` must be fully green with **20+ new tests on top of the existing 52 (72+ total)** — the slice's real gate (spec §10). Budget: 6 (Task 1) + ~7 (Task 2) + optional 1 (Task 3) + ~11 (Task 4) + ~4 (Task 5) + ~3 (Task 6) ≈ 31 new → 83+ total. Tasks 7–9 add build-only UI and must not require re-running logic tests; Task 9 re-confirms `swift test` still green.

## Task 7: SwiftUI gameplay views (app target, sources only — inspection this task, compiled in Task 8)
**Layer:** ios (app target)
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchListView.swift` — observes `MatchListViewModel`; lists matches with a court-surface badge + a date (format the raw `createdAt` string in-view only); most-recent-first (from the VM). Toolbar `+`/FAB presents `CreateMatchSheet`. Tapping a match routes by `viewModel.isActive(match)`: active → `RecordSessionView`, ended → `MatchSummaryView` (FR-V1/V2).
- `ios/TennisShotTracker/TennisShotTracker/Views/CreateMatchSheet.swift` — surface picker (hard/clay/grass) + confirm → `viewModel.create(surface:)` → route into the new match's `RecordSessionView` (FR-V3).
- `ios/TennisShotTracker/TennisShotTracker/Views/RecordSessionView.swift` — draws the static six-zone court diagram (net at top, baseline at bottom); makes ONLY the court rect tappable (`GeometryReader` + `.coordinateSpace`); on each tap calls `ZoneClassifier.classify(point:in:)` with the tap point and the diagram rect, passing the zone to `viewModel.record(zone:)`; shows `viewModel.count`, the last-N shots, and an End Match button calling `viewModel.endMatch()` → route to summary (FR-V4). No zone math beyond calling `ZoneClassifier` (AC30).
- `ios/TennisShotTracker/TennisShotTracker/Views/MatchSummaryView.swift` — renders `MatchSummaryViewModel.entries` as a bar/grid keyed by zone (FR-V5).
- `ios/TennisShotTracker/TennisShotTracker/Views/TabShellView.swift` — MODIFY: replace `HomePlaceholderView()` with `MatchListView(...)`; replace `RecordPlaceholderView()` with the record-flow entry. Profile tab unchanged.
- `ios/TennisShotTracker/TennisShotTracker/TennisShotTrackerApp.swift` — MODIFY: construct a `MatchClient` from the SAME `APIConfig`/`URLSessionTransport`/`KeychainTokenStore` used for `APIClient`; inject into the gameplay views/VMs. Wiring only, no logic.
- DELETE `ios/TennisShotTracker/TennisShotTracker/Views/HomePlaceholderView.swift` and `RecordPlaceholderView.swift` (superseded — AC29).
**Depends on:** Task 6 (all three VMs), Task 2 (ZoneClassifier), Task 4 (MatchClient)
**Acceptance (by inspection this task; compiled in Task 8) (AC29, AC30, AC31):** app-target files contain NO networking, decoding, zone-mapping, or shot-list logic — every such call is a TennisCore method; views observe `@Observable` VMs (AC30). `HomePlaceholderView`/`RecordPlaceholderView` are removed and superseded by `MatchListView`/`RecordSessionView`; the Home tab shows the list and Record leads into the create/session flow (AC29). No new dependency added to the app target or `Package.swift` (AC31).
**Test:** none runnable yet (build proven in Task 8). Verification is inspection against AC29/AC30/AC31.

## Task 8: Wire views into the .xcodeproj + build the app target
**Layer:** ios (app target / project file)
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — add the four new view files (`MatchListView`, `CreateMatchSheet`, `RecordSessionView`, `MatchSummaryView`) to the app-target Sources build phase; remove the two deleted placeholder files from the build phase. No change to the local-package reference (TennisCore already linked from Slice 2).
**Depends on:** Task 7 (view sources exist)
**Acceptance (AC28):**
```
xcodebuild build \
  -project ios/TennisShotTracker/TennisShotTracker.xcodeproj \
  -scheme TennisShotTracker \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```
succeeds (compile-only; no runtime; no signing). **If the iOS platform destination is unresolvable as in Slice 2 (env-blocked, spec §9),** fall back to the Slice-2 compensator: `swiftc -typecheck` all `ios/TennisShotTracker/TennisShotTracker/**/*.swift` against the iOS-built `TennisCore` module (`-sdk iphoneos -target arm64-apple-ios17.0`) exits 0. Record which path was used for Gate 2. A build-env failure is NOT a code defect and must not block the green TennisCore work.
**Test:** the `xcodebuild build` command returns exit 0 (or the type-check compensator exits 0, deviation recorded). No simulator run, no `swift test` dependency.

## Task 9: Final gate pass (both gates)
**Layer:** ios (verification)
**Files to create/modify:** none (verification + any last fixes surfaced by the gates).
**Depends on:** Task 6 (swift test green) and Task 8 (build green)
**Acceptance (spec §10):**
1. `cd ios/TennisCore && swift test` → all TennisCore tests pass, **20+ new / 72+ total** (the real gate; AC1–AC27 + OQ-2). Record the exact new/total count.
2. `xcodebuild build` (Task 8 command) → exit 0 (AC28), OR the type-check compensator exits 0 with the deviation recorded (env-blocked, spec §9).
3. By inspection: AC29 (placeholders replaced; Home = list, Record = create/session flow), AC30 (no logic in app target), AC31 (no new dependency) hold.
Deferred and explicitly NOT gated this slice: iOS simulator/UI tests, iOS CI job, and any runtime rendering / tap-routing / live-submit assertions (spec §9). The PR-base decision (stack on `feat/ios-auth-shell` vs rebase onto `main`) is a Gate-2 human decision (spec §2b) — not resolved here.
**Test:** run both gate commands; confirm green. Record which ACs each command proves and the new/total test count.

---

## AC → Task coverage matrix

| AC | Task(s) |
|---|---|
| AC1 (MatchResponse String ids, ended_at null→nil) | 1 |
| AC2 (non-null ended_at → non-nil) | 1 |
| AC3 (ShotResponse String ids) | 1 |
| AC4 (SummaryEntry count Int) | 1 |
| AC5 (CreateMatchRequest encode) | 1 |
| AC6 (AddShotsRequest + ShotInput source encodes) | 1 |
| AC7 (createMatch POST + parse) | 4 |
| AC8 (listMatches GET array) | 4 |
| AC9 (getMatch GET one) | 4 |
| AC10 (endMatch POST → ended) | 4 |
| AC11 (addShots POST → Int count) | 4 |
| AC12 (listShots GET array) | 4 |
| AC13 (getSummary GET array) | 4 |
| AC14 (Bearer on all 7) | 3 (executor), 4 |
| AC15 (401→invalidCredentials, 400→validation) | 3 (mapError), 4 |
| AC16 (transport throw → .transport) | 3 (performSend), 4 |
| AC17 (hermetic StubTransport) | 4 |
| AC18 (six centers → six strings) | 2 |
| AC19 (midX right-owned) | 2 |
| AC20 (h/3→mid, 2h/3→deep) | 2 |
| AC21 (four corners) | 2 |
| AC22 (out-of-rect clamp) | 2 |
| AC23 (never non-enum string) | 2 |
| AC24 (shot never dropped on transport error) | 6 |
| AC25 (N taps → N ordered shots; endMatch called) | 6 |
| AC26 (active/ended routing) | 5 |
| AC27 (summary load + error surface) | 5 |
| AC28 (xcodebuild build succeeds / type-check compensator) | 8, 9 |
| AC29 (placeholders replaced; list + flow) | 7, 9 |
| AC30 (no logic in app target — inspection) | 7, 9 |
| AC31 (no new dependency) | 7, 9 |
| OQ-2 degenerate-rect fallback (no numbered AC) | 2 |
| Refactor guarantee: 52 existing tests stay green | 3 |

Every AC1–AC31 maps to at least one task; OQ-2 is covered by Task 2; the RequestExecutor refactor's no-regression guarantee is Task 3. No orphans.

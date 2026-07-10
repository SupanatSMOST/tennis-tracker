# Code Review: iOS App — Gameplay Screens (Phase 1, Slice 4)

**Date:** 2026-07-10
**Reviewer:** reviewer (AI)
**Verdict:** APPROVED

## Scope

Reviewed the NEW gameplay work on `feat/ios-gameplay` vs `main`: `MatchModels`,
`ZoneClassifier`, `RequestExecutor` (extraction refactor), `MatchClient`, the 3
ViewModels, the 4 SwiftUI views + tab wiring. Pre-existing auth-shell code
(APIClient public surface, transport, TokenStore, SessionStore, the 52 existing
tests) was noted but not re-litigated, per the review brief and spec §2b.

Gate confirmed independently: `cd ios/TennisCore && swift test` → **86 tests, 0
failures** (52 pre-existing + 34 new; exceeds the 20+/72+ target).

## Spec Compliance (31 ACs)

**MatchModels decoding**
- [x] AC1: `MatchResponse` decodes String ids + `ended_at:null`→nil — `MatchModelDecodingTests.testMatchResponse_endedAtNull_decodesNil` ✅
- [x] AC2: non-null `ended_at`→non-nil, active/ended discriminable — same file ✅
- [x] AC3: `ShotResponse` all-String ids ✅
- [x] AC4: `SummaryEntry.count` as Int ✅
- [x] AC5: `CreateMatchRequest` → exactly `{"court_surface":...}` (asserts key count==1) ✅
- [x] AC6: `AddShotsRequest`+`ShotInput` — `source:"manual"` present in JSON (stored property, not just init default) ✅

**MatchClient behavior**
- [x] AC7–AC13: all seven methods issue the correct verb+path and parse the return type — `MatchClientTests` per-method tests ✅
- [x] AC14: Bearer header asserted on every one of the seven methods ✅
- [x] AC15: 401→invalidCredentials, 400→validation via shared `mapError` ✅
- [x] AC16: transport throw → `.transport`, distinct from HTTP status ✅
- [x] AC17: all tests use injected `StubTransport`, no live backend ✅

**ZoneClassifier geometry**
- [x] AC18: six cell centers → six strings (1:1) ✅
- [x] AC19: `x==midX` right-owned ✅
- [x] AC20: `y==h/3`→mid, `y==2h/3`→deep (greater-coordinate-owned) ✅
- [x] AC21: four corners deterministic ✅
- [x] AC22: out-of-rect clamps to a valid zone ✅
- [x] AC23: grid sweep never returns a non-enum string ✅
- [x] OQ-2 (no numbered AC): degenerate rect → `front_court_left`, explicit test present ✅

**ViewModels**
- [x] AC24 (load-bearing): transport error retains shot as `.failed`, never removed; count unchanged — `RecordSessionViewModelTests.testRecord_transportError_shotRetainedAsFailed` ✅
- [x] AC25: N taps → N ordered `.confirmed` shots; `endMatch()` calls `endMatch(id:)` with the active id (path asserted to contain matchID + end with `/end`) ✅
- [x] AC26: `isActive = endedAt == nil` routing ✅
- [x] AC27: summary load + error-surface-no-crash ✅

**App target (build/inspection)**
- [x] AC28: `xcodebuild build` env-blocked (iOS platform not installed, same as Slice 2). App-target compilation is verified by the orchestrator-confirmed `swiftc -typecheck` iOS-SDK compensator (exits 0), not by `swift test` (which compiles TennisCore only). `swift test` green remains the slice's real logic gate.
- [x] AC29: `HomePlaceholderView`/`RecordPlaceholderView` deleted (0 refs remain in source or pbxproj); Home tab → `MatchListView`, Record tab → create/session flow.
- [x] AC30: views hold no networking/decoding/zone-mapping/shot-list logic — all delegated to TennisCore (MatchClient, ZoneClassifier, the 3 VMs). Views only observe `@Observable` VMs and call `ZoneClassifier.classify`.
- [x] AC31: `Package.swift` untouched; no new third-party dep (CoreGraphics/Observation are system frameworks).

## Findings

No critical, high, or medium findings. The items below are informational only —
they match decisions already pinned in the spec/plan and require no change.

### [INFO] RequestExecutor refactor is behavior-preserving
`buildRequest`/`performSend`/`mapError`/`EmptyBody` were lifted 1:1 into
`RequestExecutor`; `APIClient` now delegates. Verified `APIClientTests.swift` has
**zero diff** vs the auth-shell base and all 52 tests stay green — the refactor's
stated acceptance bar (plan §2.1 / risk §7). `performSend` still wraps transport
throws as `.transport` *before* any status mapping, preserving the load-bearing
ordering. `EmptyBody` is correctly `internal` so MatchClient's GET methods compile.

### [INFO] 2xx success guard on MatchClient is intentional
`MatchClient` uses `(200...299).contains(status)` while `APIClient` keeps its
exact 201/200 guards. This is the architect's pinned policy (plan §2.1) because
POST status codes are unpinned in the API contract; it does not violate A-3
(which governs the request machinery + error mapping, both unchanged).

### [INFO] Zone strings byte-exact, no `out_behind`
Grep across `ios/` confirms only the six allowed strings appear and `out_behind`
is absent everywhere (source and tests). ZoneClassifier imports `CoreGraphics`
only — no UIKit/SwiftUI — so it stays macOS-`swift test`-able (FR-Z1).

### [INFO] AC24 retention shape is exactly as pinned
`record(zone:)` appends `.pending` before the POST, marks `.confirmed`/`.failed`
in the result/catch, and never removes. `count` derives from `shots.count`, so a
network blip leaves the count intact. The catch is a broad `catch` (any thrown
error retains), which is stricter than the `.transport`-only requirement and
safe.

### [INFO] Swift conventions clean
All three VMs are `@Observable`; all I/O is `async/await` with no `@escaping`
completion handlers in the new code; no new dependencies; no force-unwraps on
realistically-nil optionals; the token is read from the injected Keychain-backed
`TokenStore` only. `MatchListView` date formatting carries an explicit
`ponytail:` comment documenting the two-pass ISO parse and its upgrade path
(unpinned server timestamp format, A-7) — an acknowledged, well-marked shortcut.

## Auto-fixes Applied

None. The diff is lean and correct as submitted; no formatting, typo, or
oversight fixes were needed.

## Summary

The slice implements all 31 ACs plus the OQ-2 fallback, proven by 34 new tests
(86 total, all green). The load-bearing pieces — the behavior-preserving
`RequestExecutor` extraction (52 auth tests untouched and green), the AC24
never-drop-a-shot retention model, byte-exact zone strings, and a UIKit-free
ZoneClassifier — are all correct. Views are genuinely thin (AC30 holds). No
changes required.

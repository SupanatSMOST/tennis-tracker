## Tennis Shot Tracker — feat(ios): gameplay screens — match list, create, live record, summary

### Summary

Delivers Phase 1, Slice 4: the full gameplay client layer on top of the auth-shell
foundation. Ships `MatchModels` (7 Codable DTOs), `ZoneClassifier` (on-device
CoreGraphics geometry), a `RequestExecutor` refactor (behavior-preserving extraction
from `APIClient`), `MatchClient` (7 gameplay endpoints), three `@Observable`
ViewModels (`MatchListViewModel`, `RecordSessionViewModel`, `MatchSummaryViewModel`),
and four SwiftUI views replacing the two auth-shell placeholders (`HomePlaceholderView`
/ `RecordPlaceholderView` deleted). The never-drop-a-shot retention model (AC24) and
byte-exact six-value zone strings are the load-bearing correctness properties.

### Links

- Spec: `docs/specs/spec-ios-gameplay-2026-07-10.md`
- Plan: `docs/plans/plan-ios-gameplay-2026-07-10.md`
- Tasks: `docs/plans/tasks-ios-gameplay-2026-07-10.md`
- Review: `docs/plans/review-ios-gameplay-2026-07-10.md` — **APPROVED**
- Security: `docs/plans/security-audit-ios-gameplay-2026-07-10.md` — **PASS**

### Changes

#### iOS — TennisCore (Swift Package)

- **`MatchModels.swift`** — `MatchResponse`, `ShotResponse`, `SummaryEntry`,
  `CreateMatchRequest`, `AddShotsRequest`, `ShotInput`, `EndMatchResponse` (7 Codable DTOs)
- **`ZoneClassifier.swift`** — on-device zone classifier; pure `CoreGraphics`; returns
  one of six fixed zone strings; degenerate-rect and out-of-rect safe
- **`RequestExecutor.swift`** — `buildRequest` / `authorizedRequest` / `performSend` /
  `mapError` / `EmptyBody` lifted 1:1 from `APIClient`; `APIClient` delegates
- **`MatchClient.swift`** — 7 endpoints: list matches, create match, get match, add shots,
  get summary, end match, list shots; 2xx success guard per plan §2.1
- **`MatchListViewModel.swift`** — loads match list, routes active/ended, surfaces errors
- **`RecordSessionViewModel.swift`** — shot retention: `.pending` → `.confirmed`/`.failed`,
  never removed; `endMatch()` asserts active id in path
- **`MatchSummaryViewModel.swift`** — loads per-match summary, surfaces errors

#### iOS — App Target

- **`MatchListView.swift`** — replaces `HomePlaceholderView`; sheet for create; routes to
  live record or summary; ISO8601 date formatting with `ponytail:` upgrade-path comment
- **`CreateMatchSheet.swift`** — court-surface picker, POST via `MatchClient`
- **`RecordSessionView.swift`** — zone tap grid; feeds `ZoneClassifier.classify` output
  to `viewModel.record(zone:)`; shot count badge; end-match button
- **`MatchSummaryView.swift`** — per-zone count table; `ContentUnavailableView` on error
- **`TabShellView.swift`**, **`RootView.swift`**, **`TennisShotTrackerApp.swift`** —
  tab wiring updated; `HomePlaceholderView` / `RecordPlaceholderView` removed

#### Docs

- `docs/specs/spec-ios-gameplay-2026-07-10.md`
- `docs/plans/plan-ios-gameplay-2026-07-10.md`
- `docs/plans/tasks-ios-gameplay-2026-07-10.md`
- `docs/plans/review-ios-gameplay-2026-07-10.md`
- `docs/plans/security-audit-ios-gameplay-2026-07-10.md`

### Acceptance Criteria

- [x] AC1–AC6: MatchModels — all 7 DTOs decode/encode correctly (null `ended_at`, String ids, `source:"manual"` stored)
- [x] AC7–AC13: MatchClient — correct verb + path for all 7 endpoints
- [x] AC14: Bearer header asserted on all 7 gameplay routes
- [x] AC15: 401→`invalidCredentials`, 400→`validation` via shared `mapError`
- [x] AC16: transport throw → `.transport`, distinct from HTTP status
- [x] AC17: all tests use injected `StubTransport`, no live backend
- [x] AC18–AC23: ZoneClassifier — 6 cell centers → 6 strings; midX/midY ownership; corner determinism; out-of-rect clamping; grid sweep never returns unknown string
- [x] AC24 (load-bearing): transport error retains shot as `.failed`, count unchanged
- [x] AC25: N taps → N ordered `.confirmed` shots; `endMatch()` path contains matchID + ends with `/end`
- [x] AC26: `isActive = endedAt == nil` routing
- [x] AC27: summary load + error-surface-no-crash
- [x] AC28: app-target compilation verified via `swiftc -typecheck` compensator (xcodebuild env-blocked — see Gate-2 disclosures)
- [x] AC29: `HomePlaceholderView` / `RecordPlaceholderView` deleted; Home → `MatchListView`, Record → create/session flow
- [x] AC30: views hold no networking/decoding/zone-mapping logic — all delegated to TennisCore
- [x] AC31: `Package.swift` untouched; no new third-party dependency

### Test Evidence

| Suite | Tests | Failures |
|-------|-------|----------|
| Pre-existing (auth-shell) | 52 | 0 |
| New gameplay | 34 | 0 |
| **Total** | **86** | **0** |

Command: `cd ios/TennisCore && swift test`

Target per spec: 72+ total / 20+ new. **Exceeded.**

AC28: `xcodebuild build` is env-blocked (iOS 26.5 Simulator platform not installed —
same constraint as Slice 2). Orchestrator-confirmed `swiftc -typecheck` compensator
exits 0; no compile errors. Full simulator / link / UI test verification deferred per
spec §9.

### Gate-2 Decisions / Disclosures

All items below are consolidated here for the Gate-2 human reviewer. No item blocks merge
unless the human decides otherwise.

---

**1. PR BASE BRANCH DECISION (human must choose)**

This is your decision. Two options:

**Option A — base on `feat/ios-auth-shell`** (recommended for a clean diff)
- GitHub diff shows only the ~13 gameplay commits; auth-shell commits are not included.
- When auth-shell's PR merges to main, GitHub auto-retargets this PR's base to main
  (standard GitHub behavior for stacked PRs). The branch does NOT orphan.
- Constraint: this PR cannot merge to main until auth-shell merges first.

**Option B — base on `main`**
- The 18 auth-shell commits ride along in this PR's diff until auth-shell merges first.
- Simpler if you want one PR to contain the full iOS history.
- Constraint: same — gameplay cannot reach main until auth-shell merges first.

Compare URLs (one-click, choose whichever base you prefer):
- Option A: https://github.com/SupanatSMOST/tennis-tracker/compare/feat/ios-auth-shell...feat/ios-gameplay?expand=1
- Option B: https://github.com/SupanatSMOST/tennis-tracker/compare/main...feat/ios-gameplay?expand=1

---

**2. Security INFO #1 — CWE-209: `error.localizedDescription` in gameplay ViewModels**

Files: `MatchListViewModel.swift`, `RecordSessionViewModel.swift`,
`MatchSummaryViewModel.swift` (shared `errorMessage(_:)` helper); surfaced in all four
views.

When `APIError.backendMessage` is `nil` (`.transport` or `.noToken` cases), the three
gameplay VMs fall back to `error.localizedDescription` and display it verbatim. This
differs from `AuthView`'s generic "Something went wrong. Please try again." fallback.

Why not higher: the bearer token is in the `Authorization` header and is never present
in a `URLError`. The description is a generic sentence (e.g. "Could not connect to the
server") — no stack trace, no raw response body, no token.

Optional fix: map the nil-`backendMessage` case to the same generic string as `AuthView`
for consistency. No behavior change beyond displayed text.

---

**3. Security INFO #2 — CWE-23: Server-issued match `id` string-interpolated into path**

Files: `MatchClient.swift` lines 51, 62, 76, 88, 99 (`"/matches/\(id)"`, etc.)

The `{id}` path segment is built by Swift string interpolation before
`config.baseURL.appendingPathComponent(path)`. In principle, an id containing `../`
could alter the constructed path.

Why not higher: the id originates exclusively from server-issued `MatchResponse.id`
(a UUID). It is never user-typed. `appendingPathComponent` also percent-encodes stray
characters. No realistic attacker-controlled path in a single-user app.

Optional defense-in-depth: percent-encode the id with a path-segment-allowed character
set, or assert it is a well-formed UUID before use.

---

**4. AC28 deviation: `xcodebuild` env-blocked**

`xcodebuild build -destination 'platform=iOS Simulator,...'` cannot run: the iOS 26.5
platform is not installed in this environment. The same constraint applied to Slice 2.
The orchestrator-confirmed compensator (`swiftc -typecheck` against the iOS SDK, exits
0) satisfies the spec §9 allowance. Full simulator/link/UI verification is deferred to
a local dev machine or CI with the full Xcode toolchain.

---

**5. Design choices already agreed in spec/plan (not defects)**

- **MatchClient 2xx success guard**: `(200...299).contains(status)` vs `APIClient`'s
  exact 201/200 guards. Intentional: POST response codes are unpinned in the API
  contract (plan §2.1).
- **404→server-error mapping**: per OQ-4/A-8 in the spec, a 404 on a server-issued id
  is treated as a server error (the server gave us the id, so if it 404s that is the
  server's fault, not a local not-found).

---

### Manual Testing

1. Run `cd ios/TennisCore && swift test` — expect 86 tests, 0 failures.
2. Build the app target on a machine with Xcode + iOS simulator installed:
   `xcodebuild build -scheme TennisShotTracker -destination 'platform=iOS Simulator,name=iPhone 16'`
3. Launch in simulator with backend running on `localhost:8080`:
   - Sign up / log in via the auth screens.
   - Home tab shows match list (empty on first run).
   - Tap "+" → Create Match sheet → choose a surface → confirm match created and appears in list.
   - Tap an active match → Record Session screen → tap six zone buttons → verify shot count increments.
   - Pull network (airplane mode) → tap zone → verify shot retained as failed (count unchanged).
   - Tap "End Match" → verify match moves to ended list.
   - Tap an ended match → Summary screen shows per-zone counts.

### Rollback

`git revert <commit>` for any individual gameplay commit — no DB migration added in this
iOS-only slice, so no `goose down` needed.

---

**Label to apply: `ai-generated`**
(The `gh` CLI is not installed in this environment. Please apply the label manually
after opening the PR on GitHub.)

---

*AI-generated PR. Human review required before merge.*

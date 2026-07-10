# Spec: iOS App — Auth + 3-Tab Shell (Phase 1, Slice 2)

**Date:** 2026-07-09
**Phase:** Phase 1 (Skeleton)
**Author:** spec-analyst (AI)
**Status:** awaiting-approval

## 1. Intent

Build the native Swift/SwiftUI client foundation on top of the backend auth
spine delivered in Slice 1 (`spec-backend-auth-foundation-2026-07-09.md`). This
slice delivers exactly three things: (1) a testable local Swift package
`ios/TennisCore` holding the API client, the auth/session/token state machine, a
Keychain wrapper, and the Codable models; (2) a thin SwiftUI app target
`TennisShotTracker` that consumes TennisCore and presents an auth screen plus a
3-tab shell (Home / Record / Profile); (3) end-to-end auth from the client's
perspective — signup (with auto-login), login, launch-time session resolution
via `GET /me`, and logout. It proves the client auth + session path without any
camera, CV, or gameplay screens. The load-bearing constraint is that all logic
worth testing lives in TennisCore and is verified by `swift test` on macOS (no
simulator), while the app target is build-only this slice.

## 2. Scope

### In scope

- **`ios/TennisCore` local Swift package (SPM):** contains ALL testable logic —
  `APIClient`, the auth/session/token state machine, the Keychain wrapper, and
  the Codable request/response models. Unit-tested via `swift test` on macOS
  (no simulator).
- **Session/routing state machine in TennisCore** (`@Observable`): resolves the
  three app states — launch/resolving, unauthenticated, authenticated — and
  exposes them so the SwiftUI shell is a dumb reader. This lives in TennisCore
  (not the app target) specifically so the gating behavior is `swift test`-verifiable.
- **`TennisShotTracker` SwiftUI app target:** a THIN shell depending on
  TennisCore. Presents the auth screen when unauthenticated and the 3-tab shell
  when authenticated. Build-only this slice (`xcodebuild build`).
- **Auth screen** supporting BOTH login and signup. Signup performs auto-login
  (stores the returned token immediately; same post-token code path as login).
- **3-tab shell (SwiftUI):** Home, Record, Profile. Home and Record are
  placeholders this slice. Profile has a working Logout that clears the Keychain
  token and returns to the auth screen.
- **Session persistence:** JWT stored in the iOS Keychain (wrapper in
  TennisCore). On launch, read the token and resolve the session; per DESIGN.md
  the session never expires until the app is deleted.
- **Configurable base URL** (default `http://localhost:8080`; deployed VPS is the
  other option). No secrets in code.
- **Hermetic TennisCore networking tests:** APIClient tests run against a stubbed
  transport (no live backend, no `localhost:8080` required) so `swift test` is
  self-contained.

### Out of scope (non-goals)

- **Camera / AVFoundation / court-framing.** Deferred (Phase 2).
- **Any CV / CoreML.** Deferred (Phase 3).
- **Gameplay CRUD screens** (match / record / summary create/read/update).
  Home and Record are placeholders only this slice.
- **Push notifications.**
- **iOS simulator/UI tests and an iOS CI job.** Deferred until a simulator
  runtime is installed (see §7 Known Technical Risk). No runtime-dependent
  assertions are acceptance criteria this slice.
- **Backend changes.** The backend contract is consumed as-is (§6); no server
  work in this slice.
- **Profile editing** (display name, avatar). Profile tab holds Logout only.

## 3. Acceptance Criteria

Each criterion is independently verifiable. ACs are split by their gate:
**TennisCore logic ACs** are proven by `swift test`; **app-target ACs** are
proven by `xcodebuild build` and by inspection (no simulator this slice).

### TennisCore — models & decoding (`swift test`)
- [ ] AC1: The signup response model decodes `{"user_id":"<string>","username":"<string>","token":"<jwt>"}`
  where `user_id` is a JSON **string** into a Swift `String` field. A model
  typing `user_id` as `UUID` would fail to decode this payload — the field MUST
  be `String`.
- [ ] AC2: The login response model decodes `{"token":"<jwt>"}` into a token
  string.
- [ ] AC3: The `GET /me` response model decodes
  `{"user_id":"<string>","username":"<string>"}` with `user_id` as `String`.
- [ ] AC4: The uniform error body `{"error":"<message>"}` decodes into a model
  that exposes the message string.

### TennisCore — APIClient behavior (`swift test`, stubbed transport)
- [ ] AC5: A `201` signup response is parsed and the returned token is stored via
  the token-store seam immediately (auto-login), using the same
  token-persistence path as login. *(Store is injectable per §9 A-8; the test
  uses an in-memory store, not the real Keychain.)*
- [ ] AC6: A `200` login response is parsed and the token is stored via the
  token-store seam. *(In-memory store under `swift test`, per §9 A-8.)*
- [ ] AC7: A `401` response maps to an "invalid credentials" client error and the
  backend's `{"error"}` message is surfaced.
- [ ] AC8: A `409` response maps to a "username already taken" client error and
  the backend's `{"error"}` message is surfaced.
- [ ] AC9: A `400` response maps to a "validation error" client error and the
  backend's `{"error"}` message is surfaced.
- [ ] AC10: `GET /me` requests are sent with an `Authorization: Bearer <jwt>`
  header carrying the stored token.
- [ ] AC11: All APIClient tests pass with no live backend running and no
  `localhost:8080` reachable (transport is stubbed/injected).

### TennisCore — Keychain wrapper (`swift test`)
- [ ] AC12: Store → read → clear round-trip: after storing a token the wrapper
  reads back the same value; after clearing, the read returns nil/absent.
  *(See OQ-3 and §7 on macOS Keychain availability under `swift test`; if the
  host Keychain is unavailable in the test environment this AC is satisfied
  against an injected storage backend and the real-Keychain path is covered by
  a deferred device/simulator test.)*

### TennisCore — session/routing state machine (`swift test`)
- [ ] AC13: With no stored token, the state machine resolves to
  **unauthenticated**.
- [ ] AC14: With a stored token and a stubbed `GET /me` returning `200`, launch
  resolution transitions to **authenticated** and exposes the resolved
  `user_id`/`username`.
- [ ] AC15: With a stored token and a stubbed `GET /me` returning `401` (invalid /
  deleted user), launch resolution clears the Keychain token and transitions to
  **unauthenticated**.
- [ ] AC16: With a stored token and a stubbed transport/offline error on `GET /me`
  at launch, the token is **retained** (not cleared) — the user is not locked
  out because the network was unreachable. Resolved state per OQ-4 (default:
  treat as authenticated-offline or a distinct error state; see OQ-4).
- [ ] AC17: A successful signup or login transitions the state machine to
  **authenticated**.
- [ ] AC18: Logout clears the Keychain token and transitions the state machine to
  **unauthenticated**.
- [ ] AC19: The configured base URL is read from a single injectable
  configuration source (default `http://localhost:8080`); no base URL or secret
  is hard-coded inside APIClient logic.

### App target — build only (`xcodebuild build`, inspection)
- [ ] AC20: `xcodebuild build` of the `TennisShotTracker` app target succeeds
  (compile-only; no simulator, no test run).
- [ ] AC21: The app target declares a dependency on the `TennisCore` package.
- [ ] AC22: By inspection, the app target contains no networking, token,
  Keychain, or model-decoding logic — that logic lives only in TennisCore.
  (Views observe TennisCore's `@Observable` state; they do not implement it.)
- [ ] AC23: By inspection, the SwiftUI root selects the auth screen when the
  state machine is unauthenticated and the 3-tab shell (Home / Record / Profile)
  when authenticated; the Profile tab wires a Logout action to the state
  machine's logout.

### Deferred (explicitly NOT acceptance criteria this slice)
- Runtime rendering of the three tabs, tapping Logout returning to the auth
  screen, and the auth screen's live submit flow — all require a simulator and
  are deferred (§7). These are covered by follow-up simulator/UI tests once a
  runtime is installed.

## 4. Functional Requirements

### iOS (Swift) — TennisCore package
- **FR-C1:** `ios/TennisCore` is a local Swift package (SPM) with a library
  product. It builds and tests on macOS via `swift test` with no simulator and
  no iOS-only dependencies in its testable code paths.
- **FR-C2:** TennisCore contains the Codable request/response models. Per the
  verified backend contract, `user_id` is decoded as a Swift `String` (the
  backend serializes the UUID via `.String()`); it MUST NOT be typed as `UUID`.
- **FR-C3:** `APIClient` performs all HTTP I/O with async/await (no completion
  handlers, per CLAUDE.md Swift conventions). Its transport is injectable so
  tests can stub responses without a live server (e.g. a `URLProtocol` stub or a
  transport protocol — mechanism is the architect's choice).
- **FR-C4:** `APIClient` exposes operations for signup, login, and fetch-me,
  each returning the decoded success model or a typed client error carrying the
  backend `{"error"}` message.
- **FR-C5:** Client error mapping from HTTP status: `401` → invalid credentials;
  `409` → username already taken; `400` → validation error (also covers
  malformed body / empty fields). In every mapped-error case the backend's
  `{"error"}` message is surfaced to the caller for display.
- **FR-C6:** A Keychain wrapper in TennisCore stores, reads, and clears the JWT.
  Token storage uses the wrapper exclusively; no other component reads/writes
  the Keychain directly. Keychain accessibility attribute per OQ-3.
- **FR-C7:** A session/routing state machine (`@Observable`) exposes the app
  state: resolving (launch), unauthenticated, authenticated (with resolved
  `user_id`/`username`). It is the single source of truth for which screen the
  shell shows.
- **FR-C8:** Launch resolution: read the token from the Keychain. If none →
  unauthenticated. If present → validate via `GET /me`. On `200` →
  authenticated. On `401` → clear the token, unauthenticated. On
  transport/offline error → retain the token (do not lock the user out); state
  per OQ-4. Per DESIGN.md the session never expires until app deletion — launch
  resolution MUST NOT expire or discard a valid token on transient failure.
- **FR-C9:** Signup uses auto-login: on `201`, store the returned `token`
  immediately and transition to authenticated via the same token-persistence
  path used by login.
- **FR-C10:** Logout clears the Keychain token via the wrapper and transitions
  the state machine to unauthenticated.
- **FR-C11:** The base URL is supplied to `APIClient` via a single injectable
  configuration value defaulting to `http://localhost:8080`, with the deployed
  VPS URL as the alternate. No base URL literal or secret is embedded in
  networking logic. Where/how the app target supplies this value (xcconfig /
  Info.plist / build setting) is an architect decision, not a spec decision
  (§9 A-4).

### iOS (Swift) — app target
- **FR-A1:** `TennisShotTracker` is a SwiftUI app target that depends on the
  `TennisCore` package and holds no testable logic (FR-C1..C11 cover the logic).
- **FR-A2:** The root view observes TennisCore's state machine and renders the
  auth screen when unauthenticated and the 3-tab shell when authenticated; while
  resolving at launch it shows a neutral loading/placeholder view.
- **FR-A3:** The auth screen supports both login and signup (username + password),
  invoking the corresponding TennisCore operations and surfacing mapped-error
  messages (§4 FR-C5). No auth logic lives in the view — it calls TennisCore.
- **FR-A4:** The 3-tab shell (SwiftUI `TabView` or equivalent) presents Home,
  Record, and Profile tabs. Home and Record are static placeholders this slice.
- **FR-A5:** The Profile tab presents a Logout control wired to TennisCore's
  logout (FR-C10).
- **FR-A6:** ViewModels, where present, are `@Observable` per CLAUDE.md; however,
  no logic that could be unit-tested may live in the app target — it belongs in
  TennisCore (AC22).

### Backend (Go)
- N/A for this slice. The backend contract (§6) is consumed as delivered in
  Slice 1. (Note: this slice resolves backend spec OQ-2 — see §9 A-1.)

### CV Pipeline (Python)
- N/A for this slice (explicit non-goal).

## 5. Data Model

No database and no schema changes in this slice. The client consumes the
backend API only. The relevant client-side data shapes are the Codable models in
§6 / FR-C2. **The one load-bearing model fact:** `user_id` is a JSON string on
the wire and MUST be a Swift `String`, not `UUID` (AC1, AC3, FR-C2).

## 6. API Contract (consumed, verified against live handlers)

The client consumes the following backend endpoints. These shapes are pinned
against the live handlers and are authoritative for this slice. All bodies are
JSON. Every failure returns the uniform error body `{"error":"<message>"}`.

### `POST /auth/signup`
- **Request body:** `{ "username": string, "password": string }`
- **201 Created:** `{ "user_id": "<string>", "username": "<string>", "token": "<jwt string>" }`
  — auto-login: the client stores the token immediately.
- **400 Bad Request:** validation error (malformed body / empty fields) —
  `{"error":"<message>"}`.
- **409 Conflict:** username already taken — `{"error":"<message>"}`.

### `POST /auth/login`
- **Request body:** `{ "username": string, "password": string }`
- **200 OK:** `{ "token": "<jwt string>" }`
- **400 Bad Request:** validation error — `{"error":"<message>"}`.
- **401 Unauthorized:** invalid credentials — `{"error":"<message>"}`.

### `GET /me` (protected)
- **Headers:** `Authorization: Bearer <jwt>`
- **200 OK:** `{ "user_id": "<string>", "username": "<string>" }`
- **401 Unauthorized:** missing/malformed/invalid token or unknown user —
  `{"error":"<message>"}`.

### Client-side status mapping (authoritative)
| HTTP status | Client meaning | Client behavior |
|---|---|---|
| `401` | invalid credentials | show error; on launch-resolution, clear token → unauthenticated |
| `409` | username already taken | show error on signup |
| `400` | validation error (incl. malformed body / empty fields) | show backend `{"error"}` message |

`user_id` is a JSON **string** in every response that carries it — decode into
`String`, never `UUID`.

## 7. Non-Functional Requirements

### Configuration / secrets
- No secrets in code; no `.env` committed (locked Universal convention). The base
  URL is configurable (default `http://localhost:8080`, alternate = deployed VPS)
  via an injectable configuration value (§4 FR-C11, §9 A-4). The JWT itself is a
  runtime value stored only in the Keychain, never in source.

### Security
- **Token at rest:** the JWT lives only in the iOS Keychain via the TennisCore
  wrapper (DESIGN.md Auth). Keychain accessibility attribute per OQ-3
  (recommendation: `kSecAttrAccessibleAfterFirstUnlock`).
- **Session lifetime:** the session never expires until the app is deleted
  (DESIGN.md). The client MUST NOT invent client-side expiry. A valid token is
  discarded only on an explicit `GET /me` `401` (server-side rejection) or on
  logout — never on a transient transport error (FR-C8, AC15, AC16).
- **Transport:** the default base URL is plaintext `http://localhost:8080` for
  local development; the deployed VPS base URL should be `https` (confirm exact
  value in OQ-1). App Transport Security exception scope for the local `http`
  default is an implementation detail flagged for the architect (§9 A-5).

### Known Technical Risk (flag)
- **No xcodegen/tuist and no iOS simulator runtime installed.** The app target's
  `.xcodeproj` must be hand-authored (minimal) so that `xcodebuild build`
  succeeds. **"App target compiles under `xcodebuild build`" is a known risk
  area** for this slice — a hand-authored project file is more fragile than a
  generated one, and there is no simulator to fall back on for validation.
- **Consequence:** iOS simulator/UI tests and an iOS CI job are **deferred**
  until a simulator runtime is installed. This slice's real test gate is
  `swift test` in TennisCore; the app target is compile-only.
- **CLAUDE.md divergence (intentional).** CLAUDE.md's Build & Test lists
  `xcodebuild test -scheme TennisShotTracker -destination 'platform=iOS Simulator,...'`.
  For this slice that command is **superseded** by the two gates in §8
  (`swift test` + `xcodebuild build`) because no simulator runtime is installed.
  This is the deferral flagged above, not an oversight; the simulator `test`
  command becomes usable again when the runtime and iOS CI job land.

### Performance
No specific latency target this slice; single-user, single-request auth flows.

## 8. Verification Gates (stated verbatim)

- `swift test` in `ios/TennisCore` passes — **this is the real test gate for the
  slice.**
- `xcodebuild build` of the app target succeeds (compile-only; no simulator).
- Explicit note: **iOS simulator/UI tests + iOS CI job are follow-ups.**

## 9. Open Questions

Called out for the human to resolve at Gate 1 before Phase 1 coding of this
slice, rather than assumed.

- **OQ-1 — Deployed VPS base URL value.** The intent notes the deployed VPS is
  the alternate base URL but does not provide the value. What is the exact VPS
  base URL (scheme + host + port)? Required to finish the base-URL configuration.
- **OQ-2 — Client-side password validation policy.** Should the client mirror the
  backend's password rules (e.g. minimum 8 characters, reject > 72 bytes to match
  bcrypt truncation) and validate before submitting, or rely solely on the
  backend `400` response and surface its `{"error"}` message? (Mirroring gives
  faster feedback but duplicates the rule; relying on the backend keeps one source
  of truth. Confirm which.)
- **OQ-3 — Keychain accessibility attribute** for the never-expiring token.
  **Recommendation: `kSecAttrAccessibleAfterFirstUnlock`** — the token survives
  reboots (available after the first device unlock) without being readable while
  the device is locked, which fits a long-lived, launch-resolved session. Please
  confirm, or choose an alternative (e.g. `...ThisDeviceOnly` variant to prevent
  iCloud Keychain sync). This also bears on OQ related to whether the host macOS
  Keychain is exercised under `swift test` (AC12) or only on device.
- **OQ-4 — Launch-time transport/offline failure behavior.** When a stored token
  exists but `GET /me` fails with a transport/offline error at launch, the token
  MUST be retained (FR-C8, AC16). But which state does the app show: (a) enter the
  authenticated shell optimistically (offline-tolerant, re-validate later), or
  (b) show a distinct "cannot reach server" retry state before entering the shell?
  Default assumed: (a) authenticated-offline is acceptable given the never-expire
  session model — confirm or override.

## 10. Assumptions

Where the inputs are silent, these are the explicit assumptions this spec makes
so the architect/coder has no undocumented decisions. Any of these the human can
override.

- **A-1 — Backend spec OQ-2 is resolved in favor of auto-login.** The Slice 1
  backend spec (`spec-backend-auth-foundation-2026-07-09.md`) left OQ-2 open
  (whether signup returns a token). The live handlers confirm signup returns
  `201 + {user_id, username, token}` with auto-login, so this client spec builds
  on that. The backend spec's §6 signup baseline should be updated to match for
  cross-document consistency; no behavior change is requested of the backend.
- **A-2 — Package/target names and layout.** The package is `ios/TennisCore` and
  the app target is `TennisShotTracker`, consistent with CLAUDE.md's `ios/`
  layout. Exact internal folder structure within the package (Views/ViewModels
  live in the app target; Models/Services/networking live in TennisCore) is the
  architect's call, subject to AC22 (no testable logic in the app target).
- **A-3 — Transport stubbing mechanism.** APIClient tests use an injected/stubbed
  transport (e.g. a `URLProtocol` stub or a protocol-based transport seam). The
  specific mechanism is an implementation decision; the requirement is only that
  `swift test` is hermetic (AC11).
- **A-4 — Base-URL delivery to the app target.** How the app target passes the
  base URL into TennisCore (xcconfig, Info.plist, build setting, or a launch
  argument) is an implementation decision. The spec fixes only: injectable,
  defaulting to `http://localhost:8080`, no hard-coded literal in logic (FR-C11).
- **A-5 — App Transport Security.** Allowing the plaintext `http://localhost:8080`
  default may require an ATS exception in the app target. Scope and mechanism of
  any ATS exception is an implementation decision flagged here; the production
  VPS URL is expected to be `https` (OQ-1).
- **A-6 — JWT/Keychain library choice.** Whether to use only Apple frameworks
  (Foundation `URLSession`, Security `Keychain` APIs) or a thin third-party
  helper is an implementation decision. The spec fixes behavior (async/await I/O,
  Keychain-only token storage, accessibility attribute per OQ-3), not the library.
- **A-7 — No JWT parsing on the client.** The client treats the JWT as an opaque
  bearer string; it does not decode or validate claims. Session validity is
  determined by `GET /me`, consistent with the backend owning token semantics.
- **A-8 — Token storage is behind an injectable seam.** In production the seam is
  the Keychain wrapper (FR-C6); under `swift test` it is an in-memory store. This
  is why AC5, AC6, AC12, AC15, and AC18 are hermetic (AC11) despite the iOS
  Keychain (`SecItem`) being unreliable in a macOS test bundle without
  entitlements. The concrete `SecItem` code path is covered by a deferred
  device/simulator test, not by `swift test` this slice.

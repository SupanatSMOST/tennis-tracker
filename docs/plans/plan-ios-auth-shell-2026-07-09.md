# Plan: iOS App — Auth + 3-Tab Shell (Phase 1, Slice 2)

**Spec:** `docs/specs/spec-ios-auth-shell-2026-07-09.md` (Gate-1 approved)
**Date:** 2026-07-09
**Author:** architect (AI)
**Branch:** `feat/ios-auth-shell` (already created — do not switch). All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Gate-1 resolutions baked in (override the spec's open questions):**
> - **OQ-1 (base URL):** default `http://localhost:8080`, kept CONFIGURABLE via an `APIConfig` seam (default value lives in `APIConfig`'s initializer, never as a literal inside request-building logic). No VPS URL supplied yet — the seam is where it is added later. No hard-coded literal in networking logic (AC19).
> - **OQ-2 (password validation):** MIRROR the backend rules client-side — min **8 characters** (runes) / reject **> 72 bytes** (UTF-8) — for instant feedback, AND still surface the backend `{"error"}` message on a `400` as the source of truth. The char/byte distinction is load-bearing (see §2.1 "Password validator").
> - **OQ-3 (Keychain accessibility):** `kSecAttrAccessibleAfterFirstUnlock` (iCloud-syncable variant). Do NOT use any `...ThisDeviceOnly` variant.
> - **OQ-4 (launch offline behavior):** OPTIMISTIC — if a stored token exists but `GET /me` fails on a transport/offline error at launch, enter the authenticated shell and retain the token; individual later calls handle their own errors.

---

## 0. Non-goals (carried forward from spec §2)

Explicitly **not** built this slice:
- **No camera / AVFoundation / court-framing** — deferred (Phase 2).
- **No CV / CoreML** — deferred (Phase 3).
- **No gameplay CRUD screens** — Home and Record are static placeholders only.
- **No push notifications.**
- **No backend changes** — the contract (§4) is consumed as delivered in Slice 1.
- **No profile editing** — Profile tab holds Logout only.
- **No iOS simulator/UI tests and no iOS CI job** — deferred until a simulator runtime is installed. The real test gate is `swift test`; the app target is compile-only (`xcodebuild build`).
- **No xcodegen/tuist** — the `.xcodeproj` is hand-authored, minimal (§2.4).

## 1. Architecture Overview

Two artifacts under `ios/`. (1) `ios/TennisCore` — a **local SPM package** with a single library product holding **all testable logic**: Codable models, an injectable `HTTPTransport` seam, `APIClient`, a `TokenStore` protocol (real `KeychainTokenStore` + `InMemoryTokenStore` for tests), a password validator, and an `@Observable` session/routing state machine. It builds and tests on macOS via `swift test` with **no simulator** and no live backend — networking tests run against a **stubbed transport** so they are hermetic (AC11). (2) `TennisShotTracker` — a **thin SwiftUI app target** that depends on TennisCore, holds **zero** testable logic (AC22), and renders screens by *observing* TennisCore's state machine: an auth screen when unauthenticated and a 3-tab shell (Home / Record / Profile) when authenticated; Profile wires a Logout to the state machine. The app target is **build-only** this slice via `xcodebuild build`. The `.xcodeproj` is **hand-authored** (no generator) and is treated as an isolated, higher-risk step so a project-file failure cannot block the TennisCore work. The base URL enters `APIClient` through a single injectable `APIConfig` value (default `http://localhost:8080`); the app target supplies it via Info.plist with an ATS exception for the plaintext localhost default.

## 2. Component Design

### 2.1 iOS (Swift) — `ios/TennisCore` package

**Package layout (all new; `ios/` is greenfield):**

```
ios/
└── TennisCore/
    ├── Package.swift                         # library product; platform floor macOS 14 / iOS 17 (§ Package.swift)
    ├── Sources/
    │   └── TennisCore/
    │       ├── Models/
    │       │   ├── AuthModels.swift           # SignupResponse, LoginResponse, MeResponse, ErrorResponse (Codable)
    │       │   └── Credentials.swift          # SignupRequest / LoginRequest encodable bodies (username, password)
    │       ├── Networking/
    │       │   ├── APIConfig.swift            # base-URL seam; default http://localhost:8080
    │       │   ├── HTTPTransport.swift        # protocol seam + URLSessionTransport (real)
    │       │   ├── APIClient.swift            # signup / login / fetchMe; status→typed-error mapping; Bearer header
    │       │   └── APIError.swift             # typed client errors carrying the backend {"error"} message
    │       ├── Auth/
    │       │   ├── TokenStore.swift           # TokenStore protocol + InMemoryTokenStore
    │       │   ├── KeychainTokenStore.swift   # SecItem impl; kSecAttrAccessibleAfterFirstUnlock (OQ-3)
    │       │   └── PasswordValidator.swift     # mirror backend: >=8 chars, <=72 bytes (OQ-2)
    │       └── Session/
    │           └── SessionStore.swift         # @Observable state machine: resolving / unauthenticated / authenticated
    └── Tests/
        └── TennisCoreTests/
            ├── ModelDecodingTests.swift        # AC1–AC4
            ├── APIClientTests.swift            # AC5–AC11, AC19
            ├── StubTransport.swift             # test helper: canned response OR thrown error
            ├── TokenStoreTests.swift           # AC12 (in-memory)
            ├── PasswordValidatorTests.swift    # OQ-2 mirror rules
            └── SessionStoreTests.swift          # AC13–AC18
```

**`Package.swift` (platform floor is load-bearing).** `@Observable` (the Observation framework) requires **macOS 14+ / iOS 17+**. The manifest MUST declare `platforms: [.macOS(.v14), .iOS(.v17)]`, or the macro will not build on the macOS host under `swift test`. One library product `TennisCore`; one test target `TennisCoreTests` depending on it. **No third-party dependencies** — Foundation (`URLSession`, Codable) and Security (Keychain) only (spec A-6). **Testing framework: XCTest** (conservative, always present in the toolchain; do not use swift-testing this slice to avoid a toolchain-version gamble).

**Codable models (`Models/`).** The one load-bearing fact: `user_id` is a JSON **string** on the wire and MUST be a Swift `String`, never `UUID` (AC1, AC3, FR-C2). A `UUID` field would fail to decode the payload.

```swift
struct SignupResponse: Decodable { let userId: String; let username: String; let token: String }   // user_id → String
struct LoginResponse:  Decodable { let token: String }
struct MeResponse:     Decodable { let userId: String; let username: String }                        // user_id → String
struct ErrorResponse:  Decodable { let error: String }                                               // uniform {"error"} body
```

Decode `user_id` → `userId` via `CodingKeys` (or a `.convertFromSnakeCase` decoder — coder's choice, but be consistent). Request bodies (`SignupRequest`, `LoginRequest`) are `Encodable` `{username, password}`.

**Transport seam (`HTTPTransport.swift`) — the single most load-bearing seam.** One protocol; the stub must be able to **return a canned `(Data, HTTPURLResponse)`** (for the 200/201/400/401/409 paths) **AND throw** an error (for the offline/transport path, AC16). If the seam could only return responses, AC16 would be inexpressible.

```swift
protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionTransport: HTTPTransport { /* wraps URLSession.data(for:) → cast response to HTTPURLResponse */ }
```

The real `URLSessionTransport` is the only place `URLSession` is instantiated; because tests inject a stub, `swift test` never touches the network (AC11).

**`APIConfig.swift` — base-URL seam (AC19).**

```swift
struct APIConfig {
    let baseURL: URL
    init(baseURL: URL = URL(string: "http://localhost:8080")!) { self.baseURL = baseURL }  // the only default literal, in the seam
}
```

The default literal lives here (allowed — this IS the seam). `APIClient` request-building reads `config.baseURL` and MUST NOT contain any URL literal (AC19). The VPS URL is added later by constructing `APIConfig(baseURL:)` with a different value; no logic change needed.

**`APIClient.swift` (async/await, no completion handlers — FR-C3).**

```swift
final class APIClient {
    init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore)
    func signup(username: String, password: String) async throws -> SignupResponse   // POST /auth/signup; on 201 stores token
    func login(username: String, password: String)  async throws -> LoginResponse    // POST /auth/login;  on 200 stores token
    func fetchMe() async throws -> MeResponse                                         // GET /me; Authorization: Bearer <stored token>
}
```

- **Token persistence path (FR-C9 — shared).** On `201` signup and `200` login, `APIClient` stores the returned token via `tokenStore.set(token)` — the **same** persistence call for both, so signup auto-login uses login's exact post-token path (AC5, AC6).
- **`fetchMe` Bearer header (AC10).** Reads the token from `tokenStore`, sets `Authorization: Bearer <token>`. If no token is stored, throws an `APIError` (do not send an unauthenticated `/me`).
- **Status → typed error mapping (FR-C5).** Non-2xx responses decode the `{"error"}` body and throw an `APIError` carrying both a case and the backend message:
  - `400` → `.validation(message)` (AC9)
  - `401` → `.invalidCredentials(message)` (AC7)
  - `409` → `.usernameTaken(message)` (AC8)
  - other non-2xx → `.server(status, message)`
  - transport failure (thrown by the seam) propagates as `.transport(underlyingError)` (AC16 relies on this being distinguishable from an HTTP error).

**`APIError.swift`.** An `enum APIError: Error` with the cases above; each mapped-HTTP case carries the backend `{"error"}` `message: String` so the view can display the server's text as source of truth (FR-C5, OQ-2). A `.transport` case wraps the underlying `URLError`/thrown error and is what the session state machine keys off for the optimistic-offline branch (AC16).

**`TokenStore.swift` — injectable token seam (A-8).**

```swift
protocol TokenStore {
    func get() -> String?
    func set(_ token: String)
    func clear()
}
final class InMemoryTokenStore: TokenStore { /* dictionary/var-backed; used under swift test */ }
```

The protocol is the injection point used by BOTH `APIClient` and `SessionStore`. No component touches the Keychain except `KeychainTokenStore`.

**`KeychainTokenStore.swift` (production; OQ-3).** `SecItem` add/update/copy/delete against a fixed service+account, with `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock` (the iCloud-syncable variant; **not** `...ThisDeviceOnly`). This compiles on the macOS host (Security framework is present) but is **not** exercised by `swift test` — AC12 runs against `InMemoryTokenStore` because `SecItem` is unreliable in an unsigned macOS test bundle (A-8). The real `SecItem` path is a deferred device/simulator test.

**`PasswordValidator.swift` (OQ-2 — has no numbered AC; do not drop it).** A pure function mirroring the backend exactly: reject `< 8` **characters** (Swift `String.count`, i.e. runes) and reject `> 72` **bytes** (`String.utf8.count`). This gives instant client-side feedback BEFORE a network call. It does not replace the backend `400`: when the client submits anyway (or the backend disagrees), the `APIError.validation(message)` still surfaces the backend's `{"error"}` text as source of truth. The char-vs-byte distinction is load-bearing and matches the backend (8 runes / 72 bytes).

**`SessionStore.swift` — `@Observable` session/routing state machine (FR-C7, single source of truth).** The state enum MUST allow **authenticated without resolved user info** so the optimistic-offline path (AC16) is representable — if `authenticated` required a `MeResponse`, AC16 could not be constructed:

```swift
enum SessionState {
    case resolving                         // launch, before /me resolves
    case unauthenticated
    case authenticated(me: MeResponse?)    // me == nil ⇒ optimistic-offline (AC16); me != nil ⇒ resolved (AC14)
}

@Observable final class SessionStore {
    private(set) var state: SessionState = .resolving
    init(client: APIClient, tokenStore: TokenStore)
    func resolve() async     // launch resolution (FR-C8)
    func signup(username:password:) async throws   // → authenticated (AC17)
    func login(username:password:)  async throws   // → authenticated (AC17)
    func logout()            // clears token, → unauthenticated (AC18)
}
```

- **`resolve()` (launch, FR-C8).** Read token from `tokenStore`. **No token →** `.unauthenticated` (AC13). **Token present →** call `client.fetchMe()`:
  - `200` → `.authenticated(me: resolved)` exposing `user_id`/`username` (AC14).
  - `401` (`APIError.invalidCredentials`) → `tokenStore.clear()`, `.unauthenticated` (AC15).
  - **transport/offline error** (`APIError.transport`) → **retain** the token, `.authenticated(me: nil)` — optimistic per OQ-4 (AC16). MUST NOT clear the token on a transient failure (DESIGN.md: session never expires until app deletion).
- **`signup` / `login`.** Delegate to `APIClient` (which persists the token on success), then set `.authenticated(me:)` — signup may set `me` from the signup response's `user_id`/`username`; login sets `.authenticated(me: nil)` or triggers a `fetchMe` (coder's choice, but both transition to authenticated — AC17). On thrown `APIError`, state stays unauthenticated and the error propagates to the view for display.
- **`logout`.** `tokenStore.clear()` → `.unauthenticated` (AC18). Synchronous; no network call.

> **Fallback if `@Observable` fights the toolchain** (spec/advisor risk): keep the pure transition logic in a plain, fully-testable type and have a thin `@Observable` wrapper delegate to it. Try direct `@Observable` first — AC13–AC18 want the state machine verified by `swift test`, and a plain type is still `swift test`-verifiable.

### 2.2 iOS (Swift) — `TennisShotTracker` app target (thin shell, build-only)

**Layout (all new):**

```
ios/
└── TennisShotTracker/
    ├── TennisShotTrackerApp.swift    # @main App; owns the SessionStore; calls resolve() at launch
    ├── RootView.swift                 # observes SessionStore.state → routes to Auth / TabShell / loading
    ├── Views/
    │   ├── AuthView.swift             # login + signup (username/password); calls SessionStore; shows APIError message
    │   ├── TabShellView.swift         # TabView: Home / Record / Profile
    │   ├── HomePlaceholderView.swift  # static placeholder
    │   ├── RecordPlaceholderView.swift# static placeholder
    │   └── ProfileView.swift          # Logout button → SessionStore.logout()
    └── Info.plist                     # base-URL value + ATS exception for http://localhost (§2.3)
```

- **`TennisShotTrackerApp` (FR-A1).** `@main`; constructs `APIConfig` (base URL read from Info.plist, default `http://localhost:8080`), `KeychainTokenStore`, `URLSessionTransport`, `APIClient`, and the `SessionStore`; on launch calls `await sessionStore.resolve()`. Holds no testable logic.
- **`RootView` (FR-A2, AC23).** Reads `sessionStore.state`: `.resolving` → neutral loading view; `.unauthenticated` → `AuthView`; `.authenticated` → `TabShellView`. This routing is inspection-verified (no simulator).
- **`AuthView` (FR-A3).** Username + password fields, a login/signup toggle, submit calls `sessionStore.login`/`.signup`. May call `PasswordValidator` for instant feedback (OQ-2) but must still surface the thrown `APIError`'s backend message. **No auth logic in the view** — it only calls TennisCore (AC22).
- **`TabShellView` (FR-A4).** `TabView` with Home, Record (static placeholders), Profile.
- **`ProfileView` (FR-A5, AC23).** A Logout control calling `sessionStore.logout()`.
- **AC22 discipline:** the app target contains **no** networking, token, Keychain, model-decoding, or validation logic — every such call is a method on a TennisCore type. Views observe `@Observable` state; they never implement it.

### 2.3 Base-URL config seam + ATS (A-4, A-5)

- **Delivery:** the app target puts a `TENNIS_API_BASE_URL` key in **Info.plist** (value `http://localhost:8080` this slice). `TennisShotTrackerApp` reads it (falling back to the `APIConfig` default if absent) and passes it to `APIConfig(baseURL:)`. Switching to the VPS later is an Info.plist value change (and eventually an xcconfig-driven value), not a code change — the injectable seam already exists in TennisCore.
- **ATS:** because the default base URL is plaintext `http://localhost`, add an **App Transport Security** exception in Info.plist scoped to `localhost` (`NSAppTransportSecurity` → `NSExceptionDomains` → `localhost` → `NSExceptionAllowsInsecureHTTPLoads`). This is **runtime-only** and does NOT affect `xcodebuild build` (AC20) — it is included for completeness so the app can actually reach localhost when eventually run. The production VPS URL is expected to be `https` (no exception needed then).

### 2.4 The hand-authored `.xcodeproj` (isolated risk task — §2.5, its own task)

No xcodegen/tuist. `TennisShotTracker.xcodeproj/project.pbxproj` is written by hand, minimal. The **named fragile mechanic** is the local-SPM-package reference in the pbxproj: an `XCLocalSwiftPackageReference` pointing at `../TennisCore` plus an `XCSwiftPackageProductDependency` linking the `TennisCore` product into the app target (AC21). Getting this wrong is the most likely way AC20 fails.

**Bring-up is minimal-first** (so a project-file failure cannot block TennisCore):
1. Author the pbxproj with a trivial `@main App` + an empty `ContentView` that merely `import TennisCore` and reference one symbol, linking the local package.
2. Prove `xcodebuild build` is green with that trivial shell.
3. Only then add the real shell views (they are plain SwiftUI over TennisCore and add no project-file risk).

**Exact build command (build ≠ run; no runtime, no signing needed):**

```
xcodebuild build \
  -project ios/TennisShotTracker/TennisShotTracker.xcodeproj \
  -scheme TennisShotTracker \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Building against the simulator **SDK** requires no *booted* runtime; `CODE_SIGNING_ALLOWED=NO` avoids provisioning. This is the AC20 gate. A shared scheme (`TennisShotTracker.xcodeproj/xcshareddata/xcschemes/TennisShotTracker.xcscheme`) must be authored so `-scheme` resolves.

### 2.5 CV Pipeline (Python)

**N/A** — explicit non-goal for this slice.

## 3. Data Model Changes

**None.** No database, no schema, no migration. The client consumes the backend API only. The sole client-side data-shape fact: `user_id` is a JSON **string** → Swift `String`, never `UUID` (§2.1 models, AC1/AC3).

## 4. API Contract (consumed as delivered in Slice 1; authoritative for the client)

All bodies JSON. Every failure returns the uniform `{"error":"<message>"}`.

### `POST /auth/signup`
- **Request:** `{ "username": string, "password": string }`
- **201:** `{ "user_id": "<string>", "username": "<string>", "token": "<jwt>" }` — auto-login: client stores token immediately.
- **400:** validation error — `{"error":"<message>"}`.
- **409:** username already taken — `{"error":"<message>"}`.

### `POST /auth/login`
- **Request:** `{ "username": string, "password": string }`
- **200:** `{ "token": "<jwt>" }`
- **400:** validation error — `{"error":"<message>"}`.
- **401:** invalid credentials — `{"error":"<message>"}`.

### `GET /me` (protected)
- **Headers:** `Authorization: Bearer <jwt>`
- **200:** `{ "user_id": "<string>", "username": "<string>" }`
- **401:** missing/malformed/invalid token or unknown user — `{"error":"<message>"}`.

**Client status mapping (authoritative):** `401` → invalid credentials (on launch-resolution, clear token → unauthenticated); `409` → username taken; `400` → validation error. In every mapped case the backend `{"error"}` message is surfaced. A thrown transport error (offline) is distinct from any HTTP status and drives the optimistic-offline branch (AC16). `user_id` is always a JSON string → decode `String`.

## 5. Sequence Diagrams (text)

**Launch resolution (FR-C8):**
1. App boots; `SessionStore.state = .resolving`; `resolve()` runs.
2. `tokenStore.get()`. Nil → `.unauthenticated` (AC13). Present → step 3.
3. `client.fetchMe()` with `Authorization: Bearer <token>`.
4. `200` → `.authenticated(me: resolved)` (AC14).
5. `401` (`APIError.invalidCredentials`) → `tokenStore.clear()` → `.unauthenticated` (AC15).
6. transport/offline (`APIError.transport`) → retain token → `.authenticated(me: nil)` (AC16).

**Signup (auto-login, shared token path — FR-C9):**
1. `AuthView` calls `SessionStore.signup(username, password)` (optional client `PasswordValidator` pre-check).
2. `APIClient.signup` POSTs; `201` → `tokenStore.set(token)` (the SAME call login uses) (AC5).
3. `SessionStore` → `.authenticated(me:)` (AC17).
4. `400` → `.validation(message)` thrown; `409` → `.usernameTaken(message)` thrown; view shows the backend message (AC8, AC9).

**Login:**
1. `AuthView` calls `SessionStore.login(username, password)`.
2. `APIClient.login` POSTs; `200` → `tokenStore.set(token)` (AC6).
3. `SessionStore` → `.authenticated` (AC17).
4. `401` → `.invalidCredentials(message)` thrown; view shows backend message (AC7).

**Logout (FR-C10):**
1. `ProfileView` calls `SessionStore.logout()`.
2. `tokenStore.clear()` → `.unauthenticated` (AC18).

## 6. AC → Design coverage matrix

| AC | Satisfied by | Where |
|---|---|---|
| AC1 | `SignupResponse.userId: String` decodes string `user_id` | Models |
| AC2 | `LoginResponse.token` | Models |
| AC3 | `MeResponse.userId: String` | Models |
| AC4 | `ErrorResponse.error` | Models |
| AC5 | `signup` 201 → `tokenStore.set` (shared path) | APIClient |
| AC6 | `login` 200 → `tokenStore.set` | APIClient |
| AC7 | 401 → `.invalidCredentials(message)` | APIClient / APIError |
| AC8 | 409 → `.usernameTaken(message)` | APIClient / APIError |
| AC9 | 400 → `.validation(message)` | APIClient / APIError |
| AC10 | `fetchMe` sets `Authorization: Bearer` | APIClient |
| AC11 | injected `StubTransport`; `URLSession` never instantiated in tests | HTTPTransport seam |
| AC12 | store→read→clear round-trip against `InMemoryTokenStore` | TokenStore |
| AC13 | no token → `.unauthenticated` | SessionStore.resolve |
| AC14 | token + 200 → `.authenticated(me: resolved)` | SessionStore.resolve |
| AC15 | token + 401 → clear + `.unauthenticated` | SessionStore.resolve |
| AC16 | token + transport error → retain + `.authenticated(me: nil)` | SessionStore.resolve + `SessionState` design |
| AC17 | signup/login → `.authenticated` | SessionStore |
| AC18 | logout → clear + `.unauthenticated` | SessionStore |
| AC19 | base URL only in `APIConfig` seam; no literal in request-building | APIConfig / APIClient |
| AC20 | `xcodebuild build` green (SDK build, no runtime, no signing) | .xcodeproj task |
| AC21 | `XCLocalSwiftPackageReference` + product dependency on TennisCore | pbxproj |
| AC22 | inspection: no logic in app target | app-target layout |
| AC23 | inspection: RootView routing + Profile logout wiring | RootView / ProfileView |

Plus (Gate-1, no numbered AC): **OQ-2 client password validator** — `PasswordValidator` with its own tests (≥8 chars / ≤72 bytes).

## 7. Risks & Mitigations

- **Hand-authored pbxproj is fragile / no simulator to fall back on (spec §7).** Isolate it as its own last task; bring it up minimal-first (trivial App linking TennisCore, prove `xcodebuild build`, then add shell views). A failure there cannot block the already-green TennisCore work.
- **`@Observable` needs macOS 14 / iOS 17.** Declare the platform floor in `Package.swift`; verify the host toolchain builds the Observation macro at the SPM-skeleton task. Fallback: plain testable transition type behind a thin `@Observable` wrapper.
- **Transport seam that cannot throw would make AC16 inexpressible.** The `HTTPTransport` protocol is `async throws` and the stub can both return a canned response and throw; the offline branch keys off `APIError.transport`.
- **`authenticated` state requiring a user would make AC16 inexpressible.** `SessionState.authenticated(me: MeResponse?)` — `me == nil` is the optimistic-offline case.
- **`user_id` typed as `UUID` would fail to decode.** Fixed as `String` in the models (AC1/AC3); a decoding test pins it.
- **Base-URL literal leaking into logic (AC19).** The only literal is the `APIConfig` initializer default; a test asserts request URLs derive from an injected `APIConfig`.
- **`SecItem` unreliable in an unsigned macOS test bundle.** AC12 runs against `InMemoryTokenStore`; the real Keychain path is a deferred device/simulator test (A-8).
- **ATS/localhost worry against the build.** ATS is runtime-only; it does not threaten `xcodebuild build` (AC20). Included in Info.plist for eventual runtime.
- **Testing-framework/toolchain drift.** Pin **XCTest** explicitly; do not use swift-testing this slice.

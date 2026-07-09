# Tasks: iOS App — Auth + 3-Tab Shell (Phase 1, Slice 2)

**Plan:** `docs/plans/plan-ios-auth-shell-2026-07-09.md`
**Spec:** `docs/specs/spec-ios-auth-shell-2026-07-09.md` (Gate-1 approved)
**Total tasks:** 10
**Branch:** `feat/ios-auth-shell` (already created — do NOT switch). All work confined to `ios/` (plus these docs). Never touch anything outside `tennis-tracker/`.

> **Order (dependency-driven):** TennisCore SPM skeleton → models → token store & Keychain → transport+APIClient → password validator → session state machine (Tasks 1–6 make `swift test` green — the real gate). The `TokenStore` protocol lands before `APIClient` because `APIClient` takes it as an init parameter. Then the app-target Swift shell (Task 7, inspection-only). Then the hand-authored `.xcodeproj` build, minimal-first (Task 8), then wire the real shell views into it and re-green the build (Task 9). Task 10 is a final full-gate pass.
>
> **Conventions:** SwiftUI + MVVM; ViewModels/state machine `@Observable`; async/await for all I/O (no completion handlers); Keychain wrapper for tokens; **XCTest** (not swift-testing); conventional commits. `user_id` is a JSON STRING → Swift `String`, never `UUID`. No third-party deps. Each task is one coder pass (≤ ~200 lines new code). Migrations rule (never combine migration + app code) is N/A — no migrations this slice.

---

## Task 1: TennisCore SPM package skeleton
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Package.swift` — one library product `TennisCore`; one test target `TennisCoreTests`; `platforms: [.macOS(.v14), .iOS(.v17)]` (required for `@Observable`); **no** third-party dependencies. Swift tools version matching the host toolchain.
- `ios/TennisCore/Sources/TennisCore/TennisCore.swift` — a trivial placeholder symbol so the product builds.
- `ios/TennisCore/Tests/TennisCoreTests/SmokeTests.swift` — one trivial passing XCTest.
**Depends on:** none
**Acceptance:** `cd ios/TennisCore && swift build` and `swift test` both pass on macOS with no simulator and no network. Manifest declares the macOS 14 / iOS 17 floor and no external deps. Confirms the host toolchain builds the Observation macro path (verify by adding a throwaway `@Observable` type if `swift build` is uncertain, then remove it).
**Test:** the smoke XCTest is the check. Proves `swift test` green before any real logic (foundation for AC11 hermeticity).

## Task 2: Codable models + decoding tests
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Models/AuthModels.swift` — `SignupResponse{ userId: String; username: String; token: String }`, `LoginResponse{ token: String }`, `MeResponse{ userId: String; username: String }`, `ErrorResponse{ error: String }`. Map `user_id → userId` (CodingKeys or a snake-case decoder — be consistent). `user_id` MUST decode into `String` (a `UUID` field would fail).
- `ios/TennisCore/Sources/TennisCore/Models/Credentials.swift` — `SignupRequest`/`LoginRequest` `Encodable` `{ username, password }` producing `{"username":...,"password":...}`.
- `ios/TennisCore/Tests/TennisCoreTests/ModelDecodingTests.swift` — decode canned JSON fixtures.
**Depends on:** Task 1
**Acceptance:** signup/login/me/error JSON decode into the models; `user_id` string → `String` (AC1, AC3); `LoginResponse` token (AC2); `ErrorResponse.error` (AC4). Request encoders emit the expected keys.
**Test:** `swift test`: decode `{"user_id":"abc","username":"u","token":"t"}` → fields populated (AC1); `{"token":"t"}` (AC2); `{"user_id":"abc","username":"u"}` (AC3); `{"error":"msg"}` (AC4). A fixture with a non-UUID string `user_id` decodes fine (guards against a `UUID` regression).

## Task 3: TokenStore protocol + InMemoryTokenStore + KeychainTokenStore
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Auth/TokenStore.swift` — `protocol TokenStore { func get() -> String?; func set(_ token: String); func clear() }` + `final class InMemoryTokenStore: TokenStore`.
- `ios/TennisCore/Sources/TennisCore/Auth/KeychainTokenStore.swift` — `SecItem` add/update/copy/delete against a fixed service+account; `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock` (OQ-3; NOT any `...ThisDeviceOnly`). Compiles on macOS; not exercised by `swift test` (A-8).
- `ios/TennisCore/Tests/TennisCoreTests/TokenStoreTests.swift`.
**Depends on:** Task 1
**Acceptance:** `InMemoryTokenStore` store→read→clear round-trip: after `set`, `get` returns the value; after `clear`, `get` returns nil (AC12). `KeychainTokenStore` compiles and uses `kSecAttrAccessibleAfterFirstUnlock` (verify by inspection). TokenStore is the ONLY Keychain access point.
**Test:** `swift test`: round-trip against `InMemoryTokenStore` (AC12). Do NOT test the real Keychain under `swift test` (deferred device test per A-8).

## Task 4: Transport seam + APIConfig + APIError + APIClient (+ stub transport & tests)
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Networking/HTTPTransport.swift` — `protocol HTTPTransport { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }` + `URLSessionTransport` (real; only place `URLSession` is used).
- `ios/TennisCore/Sources/TennisCore/Networking/APIConfig.swift` — `APIConfig{ baseURL: URL }`, `init(baseURL: URL = URL(string:"http://localhost:8080")!)`. This default is the ONLY base-URL literal (AC19).
- `ios/TennisCore/Sources/TennisCore/Networking/APIError.swift` — `enum APIError: Error` with `.validation(String)`, `.invalidCredentials(String)`, `.usernameTaken(String)`, `.server(Int,String)`, `.transport(Error)`, plus a `.noToken`/similar for `fetchMe` without a stored token.
- `ios/TennisCore/Sources/TennisCore/Networking/APIClient.swift` — `init(config:transport:tokenStore:)`; `signup`, `login`, `fetchMe` (async/await, no completion handlers). Build requests from `config.baseURL` (NO literal). On `201` signup / `200` login → `tokenStore.set(token)` (the SAME call for both — shared path, FR-C9). `fetchMe` sets `Authorization: Bearer <stored token>`. Map non-2xx → decode `{"error"}` → throw `APIError` (400→validation, 401→invalidCredentials, 409→usernameTaken, else→server). A thrown transport error → `.transport`.
- `ios/TennisCore/Tests/TennisCoreTests/StubTransport.swift` — a `HTTPTransport` stub that can EITHER return a canned `(Data, HTTPURLResponse)` OR throw a supplied error (load-bearing for AC16).
- `ios/TennisCore/Tests/TennisCoreTests/APIClientTests.swift`.
**Depends on:** Task 2 (models), Task 3 (`TokenStore` protocol — `APIClient` takes it as an init parameter; tests inject `InMemoryTokenStore`).
**Acceptance:** signup `201` stores token via seam (AC5); login `200` stores token (AC6); `401`→`.invalidCredentials(message)` surfacing backend text (AC7); `409`→`.usernameTaken(message)` (AC8); `400`→`.validation(message)` (AC9); `fetchMe` sends `Authorization: Bearer <token>` (AC10); all tests use the stub — no live backend, `localhost:8080` unreachable is fine (AC11); request URLs derive from an injected `APIConfig`, no literal in request-building (AC19).
**Test:** `swift test` with `StubTransport` + `InMemoryTokenStore`: assert token stored after 201/200; assert thrown `APIError` case + carried message for 400/401/409; capture the outgoing `URLRequest` and assert the `Authorization` header and that the URL is built from an injected non-default `APIConfig` (AC19). Inject a stub that THROWS and assert `.transport`.

## Task 5: Password validator (OQ-2 mirror rules)
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Auth/PasswordValidator.swift` — pure function/type mirroring the backend: reject `< 8` **characters** (`String.count`, runes) and reject `> 72` **bytes** (`String.utf8.count`). Returns valid / a specific reason. Char-vs-byte distinction is load-bearing.
- `ios/TennisCore/Tests/TennisCoreTests/PasswordValidatorTests.swift`.
**Depends on:** Task 1
**Acceptance:** 7-char password → invalid (too short); 8-char → valid; a password whose UTF-8 byte length exceeds 72 → invalid (too long), even if its `count` is ≤ 72 (multi-byte characters); an 8-char ASCII password ≤ 72 bytes → valid. This is instant client-side feedback only — it does NOT replace the backend `400`, whose `{"error"}` message still surfaces via `APIError.validation` (Task 3).
**Test:** `swift test`: boundary cases at 7/8 chars and at the 72-byte edge using multi-byte characters (e.g. emoji) to prove the byte (not char) rule.

## Task 6: Session/routing state machine (@Observable)
**Layer:** ios (TennisCore)
**Files to create/modify:**
- `ios/TennisCore/Sources/TennisCore/Session/SessionStore.swift` — `enum SessionState { case resolving; case unauthenticated; case authenticated(me: MeResponse?) }` (the `MeResponse?` is load-bearing — `nil` = optimistic-offline, AC16). `@Observable final class SessionStore` with `private(set) var state`, `init(client:tokenStore:)`, `resolve()`, `signup`, `login`, `logout` per plan §2.1/§5.
  - `resolve()`: no token → `.unauthenticated` (AC13); token + `fetchMe` 200 → `.authenticated(me: resolved)` (AC14); token + `APIError.invalidCredentials` (401) → `tokenStore.clear()` + `.unauthenticated` (AC15); token + `APIError.transport` → RETAIN token + `.authenticated(me: nil)` (AC16).
  - `signup`/`login`: delegate to `APIClient` (persists token), then `.authenticated(...)` (AC17); rethrow `APIError` on failure (view displays it).
  - `logout()`: `tokenStore.clear()` + `.unauthenticated` (AC18); synchronous, no network.
  - If `@Observable` fights the toolchain: extract pure transition logic into a plain testable type behind a thin `@Observable` wrapper (plan §2.1 fallback).
- `ios/TennisCore/Tests/TennisCoreTests/SessionStoreTests.swift`.
**Depends on:** Task 4 (APIClient), Task 3 (TokenStore)
**Acceptance:** AC13–AC18 hold, driven entirely by a stubbed transport + `InMemoryTokenStore` (hermetic, AC11). AC16 explicitly asserts the token is RETAINED (not cleared) on transport error and state is `.authenticated(me: nil)`.
**Test:** `swift test`: (AC13) empty store → `.unauthenticated`; (AC14) store token + stub 200 `/me` → `.authenticated(me: non-nil)` exposing user_id/username; (AC15) stub 401 → token cleared + `.unauthenticated`; (AC16) stub THROWS transport error → token still present + `.authenticated(me: nil)`; (AC17) signup then login each → `.authenticated`; (AC18) logout → token cleared + `.unauthenticated`.

> **GATE CHECKPOINT:** after Task 6, `cd ios/TennisCore && swift test` must be fully green. This is the slice's real test gate (spec §8). Tasks 7–10 add the build-only app target and must not require re-running logic tests, but Task 10 re-confirms `swift test` still green.

## Task 7: App-target Swift shell sources (inspection-only, no build yet)
**Layer:** ios (app target)
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTrackerApp.swift` — `@main App`; reads `TENNIS_API_BASE_URL` from Info.plist (fallback to `APIConfig` default), constructs `APIConfig`, `KeychainTokenStore`, `URLSessionTransport`, `APIClient`, `SessionStore`; calls `await sessionStore.resolve()` at launch. No testable logic.
- `ios/TennisShotTracker/RootView.swift` — observes `sessionStore.state`: `.resolving` → loading view; `.unauthenticated` → `AuthView`; `.authenticated` → `TabShellView` (AC23).
- `ios/TennisShotTracker/Views/AuthView.swift` — login/signup toggle (username/password), submit calls `sessionStore.login`/`.signup`, shows the thrown `APIError`'s backend message; may call `PasswordValidator` for instant feedback. No auth logic in the view (AC22).
- `ios/TennisShotTracker/Views/TabShellView.swift` — `TabView` Home / Record / Profile (AC22/AC23 shell).
- `ios/TennisShotTracker/Views/HomePlaceholderView.swift`, `ios/TennisShotTracker/Views/RecordPlaceholderView.swift` — static placeholders.
- `ios/TennisShotTracker/Views/ProfileView.swift` — Logout button → `sessionStore.logout()` (AC23).
**Depends on:** Task 6 (consumes SessionStore/APIClient/APIConfig/PasswordValidator — no NEW logic)
**Acceptance (by inspection this task; compiled in Task 9):** app-target files contain NO networking/token/Keychain/model-decoding/validation logic — every such call is a TennisCore method (AC22). RootView routes auth vs 3-tab shell; Profile wires Logout to `SessionStore.logout` (AC23). Views observe `@Observable` state; they do not implement it.
**Test:** none runnable yet (no `.xcodeproj`). Verification is inspection against AC22/AC23; compile is proven in Task 9.

## Task 8: Hand-authored .xcodeproj — minimal-first build (isolated risk task)
**Layer:** ios (app target / project file)
**Files to create/modify:**
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/project.pbxproj` — hand-authored, minimal. iOS app target `TennisShotTracker`. Add an `XCLocalSwiftPackageReference` → `../TennisCore` and an `XCSwiftPackageProductDependency` linking the `TennisCore` product into the app target (AC21).
- `ios/TennisShotTracker/TennisShotTracker.xcodeproj/xcshareddata/xcschemes/TennisShotTracker.xcscheme` — shared scheme so `-scheme TennisShotTracker` resolves.
- `ios/TennisShotTracker/Info.plist` — `TENNIS_API_BASE_URL = http://localhost:8080`; ATS exception for `localhost` (`NSAppTransportSecurity → NSExceptionDomains → localhost → NSExceptionAllowsInsecureHTTPLoads`). (Runtime-only; does not affect the build.)
- **Temporarily** reduce the app sources to a trivial `@main App` + empty `ContentView` that `import TennisCore` and reference one symbol. **Park the Task-7 sources entirely** (both the real `@main TennisShotTrackerApp` AND the `Views/*` files) — move/exclude them from the target so there is exactly ONE `@main` for this build. This isolates the project-file/package-link risk from the shell views; the parked sources are restored in Task 9.
**Depends on:** Task 1 (TennisCore package must exist to link), Task 7 (source files exist; may be parked for the trivial first build)
**Acceptance (AC20, AC21):**
```
xcodebuild build \
  -project ios/TennisShotTracker/TennisShotTracker.xcodeproj \
  -scheme TennisShotTracker \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```
succeeds (compile-only; no runtime; no signing). The app target links the `TennisCore` local package (AC21). If the pbxproj fights the local-package reference, resolve THIS task before adding shell complexity — the trivial App proves the linkage independently.
**Test:** the `xcodebuild build` command above returns exit 0. No simulator run, no `swift test` dependency.

## Task 9: Restore full shell views + re-green the build
**Layer:** ios (app target)
**Files to create/modify:**
- Restore/finalize the Task-7 shell sources as the app's real content (unpark them): `TennisShotTrackerApp.swift`, `RootView.swift`, and the `Views/*` files become the built target's sources; ensure they are all listed in the pbxproj's app-target build phase.
**Depends on:** Task 8 (green trivial build), Task 7 (shell sources)
**Acceptance (AC20 with real shell, AC22, AC23):** the same `xcodebuild build` command (Task 8) succeeds with the full shell wired in. By inspection the built app target still holds no testable logic (AC22) and RootView/ProfileView satisfy AC23. Any compile error here is a plain SwiftUI/TennisCore-usage issue, isolated from the project-file mechanics already proven in Task 8.
**Test:** `xcodebuild build` (Task 8 command) → exit 0 with the real shell sources.

## Task 10: Final gate pass (both gates green)
**Layer:** ios (verification)
**Files to create/modify:** none (verification + any last fixes surfaced by the gates).
**Depends on:** Tasks 6 and 9
**Acceptance (spec §8):**
1. `cd ios/TennisCore && swift test` → all TennisCore tests pass (the real gate; AC1–AC19).
2. `xcodebuild build` (Task 8 command) → exit 0 (AC20, AC21).
3. By inspection: AC22 (no logic in app target) and AC23 (routing + Profile logout) hold.
Deferred and explicitly NOT gated this slice: iOS simulator/UI tests, iOS CI job, and any runtime rendering/logout-navigation/live-submit assertions (spec §7).
**Test:** run both gate commands; confirm green. Record which ACs each command proves.

---

## AC → Task coverage matrix

| AC | Task(s) |
|---|---|
| AC1 (signup user_id String) | 2 |
| AC2 (login token) | 2 |
| AC3 (me user_id String) | 2 |
| AC4 (error body) | 2 |
| AC5 (201 stores token, shared path) | 4 |
| AC6 (200 stores token) | 4 |
| AC7 (401 → invalid credentials + message) | 4 |
| AC8 (409 → username taken + message) | 4 |
| AC9 (400 → validation + message) | 4 |
| AC10 (Bearer header on /me) | 4 |
| AC11 (hermetic, stubbed transport) | 4, 6 |
| AC12 (token store round-trip) | 3 |
| AC13 (no token → unauthenticated) | 6 |
| AC14 (token+200 → authenticated w/ user) | 6 |
| AC15 (token+401 → clear + unauthenticated) | 6 |
| AC16 (token+transport error → retain + authenticated-offline) | 6 |
| AC17 (signup/login → authenticated) | 6 |
| AC18 (logout → clear + unauthenticated) | 6 |
| AC19 (base URL from injectable config only) | 4 |
| AC20 (xcodebuild build succeeds) | 8, 9, 10 |
| AC21 (app target depends on TennisCore) | 8 |
| AC22 (no logic in app target — inspection) | 7, 9, 10 |
| AC23 (routing + Profile logout — inspection) | 7, 9, 10 |
| OQ-2 client password validator (no numbered AC) | 5 |

Every AC1–AC23 maps to at least one task; the Gate-1 OQ-2 validator is covered by Task 5. No orphans.

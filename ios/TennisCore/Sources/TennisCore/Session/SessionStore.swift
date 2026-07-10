/// SessionStore — @Observable session/routing state machine.
///
/// Single source of truth for auth state (FR-C7). Owns the launch-resolution
/// sequence (resolve, FR-C8) and the signup/login/logout transitions (FR-C9/C10).
///
/// All testable logic lives here (AC22). The app target observes `state`
/// and routes accordingly; it never implements state transitions.

import Foundation
import Observation

// MARK: - SessionState

/// Represents the current authentication state of the app.
///
/// `authenticated(me: nil)` is the optimistic-offline case (AC16 / OQ-4):
/// the token is retained but /me could not be reached at launch. Individual
/// subsequent calls handle their own errors.
public enum SessionState {
    /// Launch-time: resolution has not completed yet.
    case resolving
    /// No valid token exists; the auth screen should be shown.
    case unauthenticated
    /// A token is present. `me` is nil only when /me could not be fetched
    /// due to a transport/offline error at launch (optimistic-offline, AC16).
    case authenticated(me: MeResponse?)
}

// MARK: - SessionStore

/// `@Observable` state machine that drives root navigation.
///
/// Inject `APIClient` and `TokenStore` for testability — tests supply a
/// `StubTransport`-backed client and an `InMemoryTokenStore` so no network
/// or Keychain is touched (AC11).
@Observable
public final class SessionStore {

    // MARK: State

    /// The current session state. Read-only from outside this type.
    public private(set) var state: SessionState = .resolving

    // MARK: Dependencies

    private let client: APIClient
    private let tokenStore: TokenStore

    // MARK: Init

    public init(client: APIClient, tokenStore: TokenStore) {
        self.client = client
        self.tokenStore = tokenStore
    }

    // MARK: - Launch resolution

    /// Resolves the session state at app launch (FR-C8).
    ///
    /// Branch table:
    /// - No stored token           → `.unauthenticated` (AC13)
    /// - Token + 200 /me           → `.authenticated(me: resolved)` (AC14)
    /// - Token + 401               → `tokenStore.clear()` + `.unauthenticated` (AC15)
    /// - Token + any other error   → retain token + `.authenticated(me: nil)` (AC16 / OQ-4)
    ///
    /// `resolve()` is non-throwing: every outcome sets `state` — callers
    /// should not need to catch (the view just reads state reactively).
    public func resolve() async {
        guard tokenStore.get() != nil else {
            state = .unauthenticated  // AC13
            return
        }

        do {
            let me = try await client.fetchMe()
            state = .authenticated(me: me)  // AC14
        } catch APIError.invalidCredentials {
            // Token is confirmed invalid — clear it so the user lands on the
            // auth screen on every future launch until they sign in again (AC15).
            tokenStore.clear()
            state = .unauthenticated
        } catch {
            // Transport failure, server error, decode error, etc. — the session
            // is not provably invalid; retain the token and enter the shell
            // optimistically. Individual later calls will surface errors as
            // needed (AC16, OQ-4: "session never expires until app deletion").
            state = .authenticated(me: nil)
        }
    }

    // MARK: - Auth transitions

    /// Signs up a new user and transitions to `.authenticated`.
    ///
    /// `APIClient.signup` stores the token on success (AC5 / FR-C9).
    /// On `APIError`, rethrows so the view can display the backend message.
    /// Sets `me` from the signup response so the resolved user is immediately
    /// available without a second /me round-trip.
    public func signup(username: String, password: String) async throws {
        let response = try await client.signup(username: username, password: password)
        // Build MeResponse from the signup payload — same module access (internal init).
        let me = MeResponse(userId: response.userId, username: response.username)
        state = .authenticated(me: me)  // AC17
    }

    /// Logs in an existing user and transitions to `.authenticated`.
    ///
    /// `APIClient.login` stores the token on success (AC6 / FR-C9).
    /// Login response does not carry user profile — set `me: nil`; a later
    /// /me call (or the nav destination) can resolve it if needed (AC17).
    /// On `APIError`, rethrows so the view can display the backend message.
    public func login(username: String, password: String) async throws {
        try await client.login(username: username, password: password)
        state = .authenticated(me: nil)  // AC17
    }

    // MARK: - Logout

    /// Clears the stored token and transitions to `.unauthenticated` (AC18).
    ///
    /// Synchronous — no network call. Called directly from ProfileView.
    public func logout() {
        tokenStore.clear()
        state = .unauthenticated  // AC18
    }
}

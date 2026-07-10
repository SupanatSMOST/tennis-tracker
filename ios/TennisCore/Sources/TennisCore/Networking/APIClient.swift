/// APIClient — all network calls for the Tennis Shot Tracker auth API.
///
/// Depends on three injected seams:
///   - APIConfig:      base URL (no literal inside this file — AC19)
///   - HTTPTransport:  the send seam; tests inject a stub (AC11)
///   - TokenStore:     token persistence; tests inject InMemoryTokenStore
///
/// Async/await only — no completion handlers (FR-C3).
/// Request machinery is delegated to the shared RequestExecutor.

import Foundation

public final class APIClient {
    private let executor: RequestExecutor
    private let tokenStore: TokenStore

    public init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore) {
        self.executor = RequestExecutor(config: config, transport: transport, tokenStore: tokenStore)
        self.tokenStore = tokenStore
    }

    // MARK: - Public API

    /// Signs up a new user. On 201 the returned token is stored immediately
    /// via the same path login uses (FR-C9 / AC5).
    @discardableResult
    public func signup(username: String, password: String) async throws -> SignupResponse {
        let body = SignupRequest(username: username, password: password)
        let request = try executor.buildRequest(method: "POST", path: "/auth/signup", body: body)
        let (data, response) = try await executor.performSend(request)
        guard response.statusCode == 201 else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        let result = try JSONDecoder().decode(SignupResponse.self, from: data)
        persistToken(result.token)   // shared token-persistence call (FR-C9)
        return result
    }

    /// Logs in an existing user. On 200 the returned token is stored via
    /// the same shared path as signup (FR-C9 / AC6).
    @discardableResult
    public func login(username: String, password: String) async throws -> LoginResponse {
        let body = LoginRequest(username: username, password: password)
        let request = try executor.buildRequest(method: "POST", path: "/auth/login", body: body)
        let (data, response) = try await executor.performSend(request)
        guard response.statusCode == 200 else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: data)
        persistToken(result.token)   // shared token-persistence call (FR-C9)
        return result
    }

    /// Fetches the authenticated user's profile.
    /// Requires a stored token; throws `.noToken` if none is present (AC10).
    @discardableResult
    public func fetchMe() async throws -> MeResponse {
        let request = try executor.authorizedRequest(
            method: "GET",
            path: "/me",
            body: nil as EmptyBody?
        )
        let (data, response) = try await executor.performSend(request)
        guard response.statusCode == 200 else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode(MeResponse.self, from: data)
    }

    // MARK: - Private helpers

    /// Shared token-persistence call site (FR-C9).
    /// Both signup and login funnel through this single line so they cannot drift.
    private func persistToken(_ token: String) {
        tokenStore.set(token)
    }
}

/// APIClient — all network calls for the Tennis Shot Tracker auth API.
///
/// Depends on three injected seams:
///   - APIConfig:      base URL (no literal inside this file — AC19)
///   - HTTPTransport:  the send seam; tests inject a stub (AC11)
///   - TokenStore:     token persistence; tests inject InMemoryTokenStore
///
/// Async/await only — no completion handlers (FR-C3).

import Foundation

public final class APIClient {
    private let config: APIConfig
    private let transport: HTTPTransport
    private let tokenStore: TokenStore

    public init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore) {
        self.config = config
        self.transport = transport
        self.tokenStore = tokenStore
    }

    // MARK: - Public API

    /// Signs up a new user. On 201 the returned token is stored immediately
    /// via the same path login uses (FR-C9 / AC5).
    @discardableResult
    public func signup(username: String, password: String) async throws -> SignupResponse {
        let body = SignupRequest(username: username, password: password)
        let request = try buildRequest(method: "POST", path: "/auth/signup", body: body)
        let (data, response) = try await performSend(request)
        guard response.statusCode == 201 else {
            throw try mapError(data: data, status: response.statusCode)
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
        let request = try buildRequest(method: "POST", path: "/auth/login", body: body)
        let (data, response) = try await performSend(request)
        guard response.statusCode == 200 else {
            throw try mapError(data: data, status: response.statusCode)
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: data)
        persistToken(result.token)   // shared token-persistence call (FR-C9)
        return result
    }

    /// Fetches the authenticated user's profile.
    /// Requires a stored token; throws `.noToken` if none is present (AC10).
    @discardableResult
    public func fetchMe() async throws -> MeResponse {
        guard let token = tokenStore.get() else {
            throw APIError.noToken
        }
        var request = try buildRequest(method: "GET", path: "/me", body: nil as EmptyBody?)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performSend(request)
        guard response.statusCode == 200 else {
            throw try mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode(MeResponse.self, from: data)
    }

    // MARK: - Private helpers

    /// Shared token-persistence call site (FR-C9).
    /// Both signup and login funnel through this single line so they cannot drift.
    private func persistToken(_ token: String) {
        tokenStore.set(token)
    }

    /// Wraps `transport.send(_:)` so transport errors are caught and re-thrown
    /// as `.transport` BEFORE any status-mapping code runs.
    /// This prevents status-mapping throws from being accidentally wrapped as
    /// `.transport` — all status checks happen outside this do/catch.
    private func performSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Builds a URLRequest from the injected config (no literal — AC19).
    private func buildRequest<Body: Encodable>(
        method: String,
        path: String,
        body: Body?
    ) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    /// Decodes the `{"error":"..."}` body and maps the HTTP status to a typed APIError.
    /// Uses `try?` for the decode so a malformed error body doesn't generate a
    /// misleading throw — falls back to a generic message instead (keeps the mapping clean).
    private func mapError(data: Data, status: Int) throws -> APIError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                      ?? "HTTP \(status)"
        switch status {
        case 400: return .validation(message)
        case 401: return .invalidCredentials(message)
        case 409: return .usernameTaken(message)
        default:  return .server(status, message)
        }
    }
}

// MARK: - Internal helpers

/// Sentinel type for requests with no body (GET endpoints).
private struct EmptyBody: Encodable {}

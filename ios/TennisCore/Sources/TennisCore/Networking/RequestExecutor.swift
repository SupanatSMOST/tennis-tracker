/// RequestExecutor — shared request-building, send, and error-mapping machinery.
///
/// Extracted from APIClient so that sibling clients (e.g. MatchClient) can reuse
/// the same transport seam without duplicating logic (A-3 / FR-M3).
///
/// All logic is lifted 1:1 from the former APIClient private helpers — no behavior change.
/// APIClient delegates to this type; MatchClient is built on it directly.

import Foundation

/// Sentinel type for requests with no body (GET endpoints and body-less POSTs).
/// Declared `internal` (not `private`) so MatchClient's GET methods can write
/// `authorizedRequest(..., body: nil as EmptyBody?)` from a sibling source file.
struct EmptyBody: Encodable {}

final class RequestExecutor {
    let config: APIConfig
    let transport: HTTPTransport
    let tokenStore: TokenStore

    init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore) {
        self.config = config
        self.transport = transport
        self.tokenStore = tokenStore
    }

    // MARK: - Request building

    /// Builds a URLRequest from the injected config (no literal — AC19).
    func buildRequest<Body: Encodable>(
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

    /// Convenience: buildRequest + `Authorization: Bearer <token>` header.
    /// Throws `.noToken` if the store is empty — before any network call is made.
    func authorizedRequest<Body: Encodable>(
        method: String,
        path: String,
        body: Body?
    ) throws -> URLRequest {
        guard let token = tokenStore.get() else {
            throw APIError.noToken
        }
        var request = try buildRequest(method: method, path: path, body: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Send

    /// Wraps `transport.send(_:)` so transport errors are caught and re-thrown
    /// as `.transport` BEFORE any status-mapping code runs.
    /// This prevents status-mapping throws from being accidentally wrapped as
    /// `.transport` — all status checks happen outside this do/catch.
    func performSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw APIError.transport(error)
        }
    }

    // MARK: - Error mapping

    /// Decodes the `{"error":"..."}` body and maps the HTTP status to a typed APIError.
    /// Uses `try?` for the decode so a malformed error body doesn't generate a
    /// misleading throw — falls back to a generic message instead.
    /// 404 falls through to `.server` — OQ-4/A-8 (no `notFound` case this slice).
    func mapError(data: Data, status: Int) throws -> APIError {
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

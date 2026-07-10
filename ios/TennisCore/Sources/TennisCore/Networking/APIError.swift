/// APIError — typed client errors carrying the backend {"error"} message.
///
/// Each HTTP-mapped case carries the backend message string so views can
/// display the server's text as source of truth (FR-C5).
/// `.transport` wraps a lower-level error and is what SessionStore keys off
/// for the optimistic-offline branch (AC16).

public enum APIError: Error {
    /// 400 — a field-level or semantic validation failure.
    case validation(String)
    /// 401 — wrong credentials (or expired/invalid token).
    case invalidCredentials(String)
    /// 409 — the requested username is already registered.
    case usernameTaken(String)
    /// Any other non-2xx status; carries the HTTP status code and backend message.
    case server(Int, String)
    /// The transport layer threw before an HTTP response was received (offline, DNS, TLS, …).
    case transport(Error)
    /// fetchMe was called but no token is stored; the caller should not send the request.
    case noToken
}

extension APIError {
    /// The backend message string carried by HTTP-mapped cases.
    /// Returns nil for `.transport` and `.noToken` (no backend message available).
    public var backendMessage: String? {
        switch self {
        case .validation(let msg),
             .invalidCredentials(let msg),
             .usernameTaken(let msg):
            return msg
        case .server(_, let msg):
            return msg
        case .transport, .noToken:
            return nil
        }
    }
}

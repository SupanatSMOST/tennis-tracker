/// APIConfig — injectable base-URL seam (AC19).
///
/// The default literal `http://localhost:8080` lives HERE and ONLY here.
/// APIClient and every other request-building site read `config.baseURL`;
/// they MUST NOT contain any URL string literal (AC19).
/// To target a different server, construct APIConfig(baseURL:) with the
/// desired URL — no code change required anywhere else.

import Foundation

public struct APIConfig {
    public let baseURL: URL

    // ponytail: force-unwrap on a hardcoded literal is intentional; the
    // string is valid by construction and this is the single seam that owns it.
    public init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
    }
}

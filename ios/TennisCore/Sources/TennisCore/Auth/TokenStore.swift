/// TokenStore — the single abstraction for JWT bearer-token persistence.
/// All code that reads or writes the auth token must go through this protocol.
/// The ONLY Keychain access point is KeychainTokenStore; nothing else imports Security.

public protocol TokenStore {
    /// Returns the stored token, or nil if none is present.
    func get() -> String?
    /// Persists the given token, replacing any previously stored value.
    func set(_ token: String)
    /// Removes any stored token.
    func clear()
}

/// In-memory implementation — used in tests and SwiftUI previews.
/// Not thread-safe; callers must synchronise externally if needed.
public final class InMemoryTokenStore: TokenStore {
    private var token: String?

    public init() {}

    public func get() -> String? {
        token
    }

    public func set(_ token: String) {
        self.token = token
    }

    public func clear() {
        token = nil
    }
}

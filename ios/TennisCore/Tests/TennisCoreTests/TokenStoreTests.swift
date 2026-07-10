import XCTest
@testable import TennisCore

// KeychainTokenStore is intentionally NOT tested here.
// Entitlement requirements make SecItem unreliable in a macOS swift test bundle (A-8).
// Those tests are deferred to an on-device XCTest run.

final class TokenStoreTests: XCTestCase {

    // MARK: - Fresh store

    func testGetOnFreshStoreReturnsNil() {
        // AC12: a newly created store holds no token.
        let store = InMemoryTokenStore()
        XCTAssertNil(store.get(), "Expected nil from a fresh InMemoryTokenStore")
    }

    // MARK: - Round-trip

    func testSetThenGetReturnsStoredValue() {
        // AC12: after set, get returns the same value.
        let store = InMemoryTokenStore()
        store.set("token-value")
        XCTAssertEqual(store.get(), "token-value")
    }

    func testSetThenClearThenGetReturnsNil() {
        // AC12: after clear, get returns nil.
        let store = InMemoryTokenStore()
        store.set("token-value")
        store.clear()
        XCTAssertNil(store.get(), "Expected nil after clear()")
    }

    // MARK: - Overwrite

    func testSecondSetOverwritesFirstValue() {
        // AC12 (implied): set is a replace, not an accumulate.
        let store = InMemoryTokenStore()
        store.set("first-token")
        store.set("second-token")
        XCTAssertEqual(store.get(), "second-token", "Expected second set to overwrite the first")
    }

    // MARK: - Clear idempotency

    func testClearOnFreshStoreIsIdempotent() {
        // Calling clear() on a store that never held a token must not crash and must return nil.
        let store = InMemoryTokenStore()
        store.clear()
        XCTAssertNil(store.get(), "Expected nil after clear() on a fresh store")
    }

    // MARK: - Protocol conformance

    func testInMemoryTokenStoreConformsToTokenStoreProtocol() {
        // Verifies the type can be used wherever a TokenStore is expected.
        let store: any TokenStore = InMemoryTokenStore()
        store.set("proto-token")
        XCTAssertEqual(store.get(), "proto-token")
        store.clear()
        XCTAssertNil(store.get())
    }
}

/// SessionStoreTests — hermetic tests for Task 6 (SessionStore state machine).
///
/// AC13–AC18 are covered. All tests use StubTransport + InMemoryTokenStore;
/// no live backend, no Keychain, no network socket opened (AC11).

import XCTest
@testable import TennisCore

final class SessionStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a fresh (tokenStore, client, store) triple wired to a given stub.
    /// The tokenStore is returned separately so tests can assert its contents.
    private func makeStore(
        stub: StubTransport
    ) -> (tokenStore: InMemoryTokenStore, client: APIClient, store: SessionStore) {
        let tokenStore = InMemoryTokenStore()
        let client = APIClient(config: APIConfig(), transport: stub, tokenStore: tokenStore)
        let store = SessionStore(client: client, tokenStore: tokenStore)
        return (tokenStore, client, store)
    }

    // MARK: - AC13: no token → resolve() → .unauthenticated

    func testResolveWithNoToken_becomesUnauthenticated() async {
        let stub = StubTransport.make(status: 200, body: #"{"user_id":"uid1","username":"alice"}"#)
        let (_, _, store) = makeStore(stub: stub)
        // tokenStore is empty — no set() called

        await store.resolve()

        if case .unauthenticated = store.state {
            // Correct — AC13
        } else {
            XCTFail("AC13: expected .unauthenticated when no token is stored, got \(store.state)")
        }
    }

    // MARK: - AC14: token + 200 /me → .authenticated(me: non-nil)

    func testResolveWithTokenAnd200Me_becomesAuthenticatedWithMe() async {
        let stub = StubTransport.make(
            status: 200,
            body: #"{"user_id":"uid-alice","username":"alice"}"#
        )
        let (tokenStore, _, store) = makeStore(stub: stub)
        tokenStore.set("tok-valid")

        await store.resolve()

        if case .authenticated(let me) = store.state {
            let unwrapped = try! XCTUnwrap(me,
                "AC14: me must be non-nil after a successful /me 200 response")
            XCTAssertEqual(unwrapped.userId, "uid-alice",
                           "AC14: resolved userId must match the stub response")
            XCTAssertEqual(unwrapped.username, "alice",
                           "AC14: resolved username must match the stub response")
        } else {
            XCTFail("AC14: expected .authenticated(me: non-nil), got \(store.state)")
        }
    }

    // MARK: - AC15: token + 401 → tokenStore cleared AND .unauthenticated

    func testResolveWith401_clearsTokenAndBecomesUnauthenticated() async {
        let stub = StubTransport.make(
            status: 401,
            body: #"{"error":"token expired"}"#
        )
        let (tokenStore, _, store) = makeStore(stub: stub)
        tokenStore.set("tok-expired")

        await store.resolve()

        XCTAssertNil(tokenStore.get(),
                     "AC15: token must be cleared from the store after a 401 response")
        if case .unauthenticated = store.state {
            // Correct — AC15
        } else {
            XCTFail("AC15: expected .unauthenticated after a 401 /me response, got \(store.state)")
        }
    }

    // MARK: - AC16 (Gate-1 OQ-4 critical): transport throw → token RETAINED + .authenticated(me: nil)

    func testResolveWithTransportError_retainsTokenAndBecomesAuthenticatedWithNilMe() async {
        struct FakeNetworkError: Error {}
        let stub = StubTransport.throwing(FakeNetworkError())
        let (tokenStore, _, store) = makeStore(stub: stub)
        tokenStore.set("tok-offline")

        await store.resolve()

        XCTAssertEqual(tokenStore.get(), "tok-offline",
                       "AC16: token must be RETAINED on a transport error — user must not be locked out")
        if case .authenticated(let me) = store.state {
            XCTAssertNil(me,
                         "AC16: me must be nil in the optimistic-offline case (transport error at launch)")
        } else {
            XCTFail("AC16: expected .authenticated(me: nil) on transport error, got \(store.state)")
        }
    }

    // MARK: - AC17: signup 201 → .authenticated(me: non-nil from payload)

    func testSignup201_becomesAuthenticatedWithMeFromPayload() async throws {
        let stub = StubTransport.make(
            status: 201,
            body: #"{"user_id":"uid-bob","username":"bob","token":"tok-signup"}"#
        )
        let (_, _, store) = makeStore(stub: stub)

        try await store.signup(username: "bob", password: "s3cret!")

        if case .authenticated(let me) = store.state {
            let unwrapped = try XCTUnwrap(me,
                "AC17: me must be non-nil after a successful signup (built from SignupResponse)")
            XCTAssertEqual(unwrapped.userId, "uid-bob",
                           "AC17: signup me.userId must match the stub payload")
            XCTAssertEqual(unwrapped.username, "bob",
                           "AC17: signup me.username must match the stub payload")
        } else {
            XCTFail("AC17: expected .authenticated after signup, got \(store.state)")
        }
    }

    // MARK: - AC17: login 200 → .authenticated(me: nil — login response carries no profile)

    func testLogin200_becomesAuthenticatedWithNilMe() async throws {
        let stub = StubTransport.make(
            status: 200,
            body: #"{"token":"tok-login"}"#
        )
        let (_, _, store) = makeStore(stub: stub)

        try await store.login(username: "alice", password: "s3cret!")

        if case .authenticated(let me) = store.state {
            XCTAssertNil(me,
                "AC17: me must be nil after login (login response carries no user profile)")
        } else {
            XCTFail("AC17: expected .authenticated after login, got \(store.state)")
        }
    }

    // MARK: - AC17 rethrow: signup on 4xx does NOT flip to authenticated

    func testSignupOn4xx_rethrowsAndDoesNotFlipState() async {
        let stub = StubTransport.make(
            status: 409,
            body: #"{"error":"username taken"}"#
        )
        let (_, _, store) = makeStore(stub: stub)

        do {
            try await store.signup(username: "alice", password: "password1")
            XCTFail("AC17-rethrow: expected signup to throw on 409")
        } catch APIError.usernameTaken {
            // Correct — error propagated up
        } catch {
            XCTFail("AC17-rethrow: wrong error type: \(error)")
        }

        // State must still be .resolving (the initial value) — never .authenticated
        if case .authenticated = store.state {
            XCTFail("AC17-rethrow: state must NOT be .authenticated after a failed signup")
        }
    }

    // MARK: - AC17 rethrow: login on 4xx does NOT flip to authenticated

    func testLoginOn4xx_rethrowsAndDoesNotFlipState() async {
        let stub = StubTransport.make(
            status: 401,
            body: #"{"error":"bad credentials"}"#
        )
        let (_, _, store) = makeStore(stub: stub)

        do {
            try await store.login(username: "alice", password: "password1")
            XCTFail("AC17-rethrow: expected login to throw on 401")
        } catch APIError.invalidCredentials {
            // Correct — error propagated up
        } catch {
            XCTFail("AC17-rethrow: wrong error type: \(error)")
        }

        // State must still be .resolving — never .authenticated
        if case .authenticated = store.state {
            XCTFail("AC17-rethrow: state must NOT be .authenticated after a failed login")
        }
    }

    // MARK: - AC18: logout → token cleared AND .unauthenticated

    func testLogout_clearsTokenAndBecomesUnauthenticated() async throws {
        // First get into authenticated state via login
        let loginStub = StubTransport.make(
            status: 200,
            body: #"{"token":"tok-session"}"#
        )
        let (tokenStore, _, store) = makeStore(stub: loginStub)
        try await store.login(username: "alice", password: "s3cret!")

        // Confirm we are authenticated before logout
        if case .authenticated = store.state {} else {
            XCTFail("AC18: prerequisite failed — store should be .authenticated before logout")
            return
        }
        XCTAssertNotNil(tokenStore.get(), "AC18: token must be present before logout")

        store.logout()

        XCTAssertNil(tokenStore.get(),
                     "AC18: token must be cleared from the store after logout")
        if case .unauthenticated = store.state {
            // Correct — AC18
        } else {
            XCTFail("AC18: expected .unauthenticated after logout, got \(store.state)")
        }
    }
}

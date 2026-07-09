/// APIClientTests — hermetic tests for Task 4 (transport + APIClient).
///
/// All tests use StubTransport + InMemoryTokenStore; no live backend is used or required.
/// AC11: localhost:8080 unreachable during `swift test` is by design — the stub never
///       opens a socket.

import XCTest
@testable import TennisCore

final class APIClientTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an APIClient wired to the given stub and a fresh InMemoryTokenStore.
    /// Returns both so tests can assert the store state.
    private func makeClient(
        stub: StubTransport,
        config: APIConfig = APIConfig(),
        store: InMemoryTokenStore = InMemoryTokenStore()
    ) -> (client: APIClient, store: InMemoryTokenStore) {
        let client = APIClient(config: config, transport: stub, tokenStore: store)
        return (client, store)
    }

    // MARK: - AC5: signup 201 stores token

    func testSignup201StoresToken() async throws {
        let stub = StubTransport.make(
            status: 201,
            body: #"{"user_id":"uid1","username":"alice","token":"tok-signup"}"#
        )
        let (client, store) = makeClient(stub: stub)

        _ = try await client.signup(username: "alice", password: "password1")

        XCTAssertEqual(store.get(), "tok-signup",
                       "AC5: token must be stored in the TokenStore after a 201 signup")
    }

    // MARK: - AC6: login 200 stores token (same path as signup)

    func testLogin200StoresToken() async throws {
        let stub = StubTransport.make(
            status: 200,
            body: #"{"token":"tok-login"}"#
        )
        let (client, store) = makeClient(stub: stub)

        _ = try await client.login(username: "alice", password: "password1")

        XCTAssertEqual(store.get(), "tok-login",
                       "AC6: token must be stored in the TokenStore after a 200 login")
    }

    // MARK: - AC6 (shared path): signup and login both funnel through persistToken

    func testSignupAndLoginShareTokenPersistencePath() async throws {
        // This test validates FR-C9: both endpoints use the same single persistToken call.
        // First signup, then login; final stored token must be the login one.
        let store = InMemoryTokenStore()

        let signupStub = StubTransport.make(
            status: 201,
            body: #"{"user_id":"uid1","username":"alice","token":"tok-signup"}"#
        )
        let signupClient = APIClient(config: APIConfig(), transport: signupStub, tokenStore: store)
        _ = try await signupClient.signup(username: "alice", password: "password1")
        XCTAssertEqual(store.get(), "tok-signup", "After signup the signup token must be stored")

        let loginStub = StubTransport.make(
            status: 200,
            body: #"{"token":"tok-login"}"#
        )
        let loginClient = APIClient(config: APIConfig(), transport: loginStub, tokenStore: store)
        _ = try await loginClient.login(username: "alice", password: "password1")
        XCTAssertEqual(store.get(), "tok-login",
                       "After login the login token must overwrite the signup token (shared path)")
    }

    // MARK: - AC7: 401 → .invalidCredentials carrying the backend message

    func testSignup401ThrowsInvalidCredentials() async throws {
        let stub = StubTransport.make(
            status: 401,
            body: #"{"error":"bad creds"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "u", password: "p")
            XCTFail("AC7: expected .invalidCredentials to be thrown")
        } catch APIError.invalidCredentials(let msg) {
            XCTAssertEqual(msg, "bad creds", "AC7: error message must carry the backend text")
        } catch {
            XCTFail("AC7: wrong error type thrown: \(error)")
        }
    }

    func testLogin401ThrowsInvalidCredentials() async throws {
        let stub = StubTransport.make(
            status: 401,
            body: #"{"error":"bad creds"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.login(username: "u", password: "p")
            XCTFail("AC7: expected .invalidCredentials to be thrown")
        } catch APIError.invalidCredentials(let msg) {
            XCTAssertEqual(msg, "bad creds", "AC7: error message must carry the backend text")
        } catch {
            XCTFail("AC7: wrong error type thrown: \(error)")
        }
    }

    // MARK: - AC8: 409 → .usernameTaken carrying the backend message

    func testSignup409ThrowsUsernameTaken() async throws {
        let stub = StubTransport.make(
            status: 409,
            body: #"{"error":"taken"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "alice", password: "password1")
            XCTFail("AC8: expected .usernameTaken to be thrown")
        } catch APIError.usernameTaken(let msg) {
            XCTAssertEqual(msg, "taken", "AC8: error message must carry the backend text")
        } catch {
            XCTFail("AC8: wrong error type thrown: \(error)")
        }
    }

    // MARK: - AC9: 400 → .validation carrying the backend message

    func testSignup400ThrowsValidation() async throws {
        let stub = StubTransport.make(
            status: 400,
            body: #"{"error":"too short"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "u", password: "p")
            XCTFail("AC9: expected .validation to be thrown")
        } catch APIError.validation(let msg) {
            XCTAssertEqual(msg, "too short", "AC9: error message must carry the backend text")
        } catch {
            XCTFail("AC9: wrong error type thrown: \(error)")
        }
    }

    func testLogin400ThrowsValidation() async throws {
        let stub = StubTransport.make(
            status: 400,
            body: #"{"error":"too short"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.login(username: "u", password: "p")
            XCTFail("AC9: expected .validation to be thrown")
        } catch APIError.validation(let msg) {
            XCTAssertEqual(msg, "too short", "AC9: error message must carry the backend text")
        } catch {
            XCTFail("AC9: wrong error type thrown: \(error)")
        }
    }

    // MARK: - AC10: fetchMe sends Authorization: Bearer <stored token>

    func testFetchMeSendsAuthorizationHeader() async throws {
        let store = InMemoryTokenStore()
        store.set("my-stored-token")

        let stub = StubTransport.make(
            status: 200,
            body: #"{"user_id":"uid1","username":"alice"}"#
        )
        let client = APIClient(config: APIConfig(), transport: stub, tokenStore: store)

        _ = try await client.fetchMe()

        let captured = try XCTUnwrap(stub.capturedRequest,
                                     "AC10: StubTransport must have captured the outgoing request")
        let authHeader = captured.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer my-stored-token",
                       "AC10: Authorization header must be 'Bearer <stored token>'")
    }

    // MARK: - AC19: request URL is built from injected APIConfig, not a hard-coded localhost

    func testRequestURLUsesInjectedBaseURL() async throws {
        let customURL = URL(string: "http://example.test:9999")!
        let config = APIConfig(baseURL: customURL)
        let stub = StubTransport.make(
            status: 201,
            body: #"{"user_id":"uid1","username":"alice","token":"t"}"#,
            url: customURL
        )
        let (client, _) = makeClient(stub: stub, config: config)

        _ = try await client.signup(username: "alice", password: "password1")

        let captured = try XCTUnwrap(stub.capturedRequest,
                                     "AC19: StubTransport must capture the outgoing request")
        XCTAssertEqual(captured.url?.scheme, "http",
                       "AC19: scheme must come from injected config")
        XCTAssertEqual(captured.url?.host, "example.test",
                       "AC19: host must come from injected config, not localhost")
        XCTAssertEqual(captured.url?.port, 9999,
                       "AC19: port must come from injected config")
    }

    // MARK: - Transport-error path: stub throws → client surfaces .transport

    func testTransportThrowSurfacesAsTransportError() async throws {
        struct FakeNetworkError: Error {}
        let stub = StubTransport.throwing(FakeNetworkError())
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "u", password: "p")
            XCTFail("Transport-error path: expected .transport to be thrown")
        } catch APIError.transport {
            // Correct: the wrapped error is surfaced, not re-mapped to another case.
            // This path is load-bearing for AC16 (Task 6 SessionStore offline branch).
        } catch {
            XCTFail("Transport-error path: wrong error type thrown: \(error)")
        }
    }

    func testTransportThrowOnLoginSurfacesAsTransportError() async throws {
        struct FakeNetworkError: Error {}
        let stub = StubTransport.throwing(FakeNetworkError())
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.login(username: "u", password: "p")
            XCTFail("Transport-error path: expected .transport to be thrown for login")
        } catch APIError.transport {
            // Correct.
        } catch {
            XCTFail("Transport-error path: wrong error type thrown: \(error)")
        }
    }

    func testTransportThrowOnFetchMeSurfacesAsTransportError() async throws {
        struct FakeNetworkError: Error {}
        let store = InMemoryTokenStore()
        store.set("tok")
        let stub = StubTransport.throwing(FakeNetworkError())
        let client = APIClient(config: APIConfig(), transport: stub, tokenStore: store)

        do {
            _ = try await client.fetchMe()
            XCTFail("Transport-error path: expected .transport to be thrown for fetchMe")
        } catch APIError.transport {
            // Correct.
        } catch {
            XCTFail("Transport-error path: wrong error type thrown: \(error)")
        }
    }

    // MARK: - noToken path: fetchMe with empty store → .noToken

    func testFetchMeWithNoTokenThrowsNoToken() async throws {
        // Store is empty (no set() called).
        let stub = StubTransport.make(status: 200, body: #"{"user_id":"u","username":"a"}"#)
        let store = InMemoryTokenStore()
        let client = APIClient(config: APIConfig(), transport: stub, tokenStore: store)

        do {
            _ = try await client.fetchMe()
            XCTFail("noToken path: expected .noToken to be thrown")
        } catch APIError.noToken {
            // Correct: no request should have been sent when there is no token.
            XCTAssertNil(stub.capturedRequest,
                         "noToken path: the stub must not have been called (no request sent)")
        } catch {
            XCTFail("noToken path: wrong error type thrown: \(error)")
        }
    }

    // MARK: - mapError fallback: unknown status → .server

    func testUnknownStatusThrowsServer() async throws {
        let stub = StubTransport.make(
            status: 503,
            body: #"{"error":"service unavailable"}"#
        )
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "u", password: "p")
            XCTFail("Expected .server to be thrown for 503")
        } catch APIError.server(let code, let msg) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(msg, "service unavailable")
        } catch {
            XCTFail("Wrong error type thrown: \(error)")
        }
    }

    // MARK: - mapError fallback: malformed error body → generic message

    func testMalformedErrorBodyFallsBackToGenericMessage() async throws {
        let stub = StubTransport.make(status: 400, body: "not json at all")
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.signup(username: "u", password: "p")
            XCTFail("Expected .validation to be thrown")
        } catch APIError.validation(let msg) {
            XCTAssertEqual(msg, "HTTP 400",
                           "Malformed error body must fall back to 'HTTP <status>' message")
        } catch {
            XCTFail("Wrong error type thrown: \(error)")
        }
    }
}

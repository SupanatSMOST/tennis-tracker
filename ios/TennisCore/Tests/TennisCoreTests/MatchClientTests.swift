/// MatchClientTests — hermetic StubTransport-backed tests for Task 4 (AC7–AC17).
///
/// All tests use StubTransport + InMemoryTokenStore; no live backend is used.
/// AC17: localhost:8080 unreachable is inherent — StubTransport never opens a socket.
///
/// Every test seeds a token into the store BEFORE calling any MatchClient method
/// because `authorizedRequest` throws `.noToken` before the transport is hit.

import XCTest
@testable import TennisCore

final class MatchClientTests: XCTestCase {

    // MARK: - Helpers

    private let matchID = "match-abc-123"
    private let token   = "test-bearer-token"

    /// Builds a MatchClient wired to the given stub with a pre-seeded token.
    private func makeClient(
        stub: StubTransport,
        config: APIConfig = APIConfig()
    ) -> (client: MatchClient, stub: StubTransport) {
        let store = InMemoryTokenStore()
        store.set(token)
        let client = MatchClient(config: config, transport: stub, tokenStore: store)
        return (client, stub)
    }

    // MARK: - Canned JSON fixtures

    private func matchJSON(endedAt: String? = nil) -> String {
        let endedStr: String
        if let e = endedAt {
            endedStr = #""\#(e)""#
        } else {
            endedStr = "null"
        }
        return """
        {"id":"m1","user_id":"u1","court_surface":"clay","created_at":"2026-01-01T00:00:00Z","ended_at":\(endedStr)}
        """
    }

    private func matchArrayJSON() -> String {
        """
        [\(matchJSON()),\(matchJSON(endedAt: "2026-01-02T00:00:00Z"))]
        """
    }

    private func shotJSON() -> String {
        """
        {"id":"s1","match_id":"m1","zone":"baseline_left","source":"manual","created_at":"2026-01-01T00:00:00Z"}
        """
    }

    private func shotArrayJSON() -> String {
        """
        [\(shotJSON()),\(shotJSON())]
        """
    }

    private func summaryArrayJSON() -> String {
        """
        [{"match_id":"m1","zone":"baseline_left","count":3},{"match_id":"m1","zone":"out_left","count":1}]
        """
    }

    // MARK: - AC7: createMatch — POST /matches, body encodes court_surface, parses MatchResponse

    func testCreateMatchPostsToMatchesAndParsesResponse() async throws {
        let stub = StubTransport.make(status: 201, body: matchJSON())
        let (client, captureStub) = makeClient(stub: stub)

        let result = try await client.createMatch(surface: "clay")

        XCTAssertEqual(result.id, "m1", "AC7: id must decode from response")
        XCTAssertEqual(result.courtSurface, "clay", "AC7: courtSurface must round-trip")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC7: request must have been sent")
        XCTAssertEqual(req.httpMethod, "POST", "AC7: method must be POST")
        XCTAssertTrue(req.url?.path.hasSuffix("/matches") == true,
                      "AC7: path must end with /matches, got \(req.url?.path ?? "nil")")

        // Assert the body encodes court_surface (AC7)
        let bodyData = try XCTUnwrap(req.httpBody, "AC7: httpBody must be set for POST with body")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "AC7: httpBody must be valid JSON object"
        )
        XCTAssertEqual(json["court_surface"] as? String, "clay",
                       "AC7: encoded body must contain court_surface key with value 'clay'")
        XCTAssertEqual(json.count, 1, "AC7: encoded body must have exactly one key (court_surface)")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC8: listMatches — GET /matches → [MatchResponse]

    func testListMatchesGetAndParsesArray() async throws {
        let stub = StubTransport.make(status: 200, body: matchArrayJSON())
        let (client, captureStub) = makeClient(stub: stub)

        let results = try await client.listMatches()

        XCTAssertEqual(results.count, 2, "AC8: must decode two matches")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC8: request must have been sent")
        XCTAssertEqual(req.httpMethod, "GET", "AC8: method must be GET")
        XCTAssertTrue(req.url?.path.hasSuffix("/matches") == true,
                      "AC8: path must end with /matches, got \(req.url?.path ?? "nil")")
        XCTAssertNil(req.httpBody, "AC8: GET must not have an httpBody")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC9: getMatch — GET /matches/{id} → MatchResponse

    func testGetMatchGetsByIdAndParsesResponse() async throws {
        let stub = StubTransport.make(status: 200, body: matchJSON())
        let (client, captureStub) = makeClient(stub: stub)

        let result = try await client.getMatch(id: matchID)

        XCTAssertEqual(result.id, "m1", "AC9: id must decode from response")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC9: request must have been sent")
        XCTAssertEqual(req.httpMethod, "GET", "AC9: method must be GET")
        XCTAssertTrue(req.url?.path.hasSuffix("/matches/\(matchID)") == true,
                      "AC9: path must end with /matches/{id}, got \(req.url?.path ?? "nil")")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC10: endMatch — POST /matches/{id}/end → MatchResponse with non-nil endedAt

    func testEndMatchPostsToEndAndReturnsEndedAt() async throws {
        let stub = StubTransport.make(status: 200, body: matchJSON(endedAt: "2026-01-02T10:00:00Z"))
        let (client, captureStub) = makeClient(stub: stub)

        let result = try await client.endMatch(id: matchID)

        XCTAssertNotNil(result.endedAt, "AC10: endedAt must be non-nil in the returned MatchResponse")
        XCTAssertEqual(result.endedAt, "2026-01-02T10:00:00Z", "AC10: endedAt must match the server value")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC10: request must have been sent")
        XCTAssertEqual(req.httpMethod, "POST", "AC10: method must be POST")
        XCTAssertTrue(req.url?.path.hasSuffix("/end") == true,
                      "AC10: path must end with /end, got \(req.url?.path ?? "nil")")
        XCTAssertTrue(req.url?.path.contains("/matches/\(matchID)") == true,
                      "AC10: path must contain /matches/{id}")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC11: addShots — POST /matches/{id}/shots, body encodes shots array → Int count

    func testAddShotsPostsShotsAndReturnsCount() async throws {
        let stub = StubTransport.make(status: 201, body: #"{"count":2}"#)
        let (client, captureStub) = makeClient(stub: stub)

        let shots = [
            ShotInput(zone: "front_court_left"),
            ShotInput(zone: "baseline_right")
        ]
        let count = try await client.addShots(matchID: matchID, shots: shots)

        XCTAssertEqual(count, 2, "AC11: returned count must equal the number of shots in the response body")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC11: request must have been sent")
        XCTAssertEqual(req.httpMethod, "POST", "AC11: method must be POST")
        XCTAssertTrue(req.url?.path.hasSuffix("/shots") == true,
                      "AC11: path must end with /shots, got \(req.url?.path ?? "nil")")
        XCTAssertTrue(req.url?.path.contains("/matches/\(matchID)") == true,
                      "AC11: path must contain /matches/{id}")

        // Assert the body encodes shots array (AC11)
        let bodyData = try XCTUnwrap(req.httpBody, "AC11: httpBody must be set")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "AC11: httpBody must be valid JSON object"
        )
        let shotsArray = try XCTUnwrap(json["shots"] as? [[String: Any]],
                                       "AC11: body must have 'shots' array")
        XCTAssertEqual(shotsArray.count, 2, "AC11: shots array must contain 2 elements")
        XCTAssertEqual(shotsArray[0]["zone"] as? String, "front_court_left",
                       "AC11: first shot zone must match")
        XCTAssertEqual(shotsArray[1]["zone"] as? String, "baseline_right",
                       "AC11: second shot zone must match")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC12: listShots — GET /matches/{id}/shots → [ShotResponse]

    func testListShotsGetAndParsesArray() async throws {
        let stub = StubTransport.make(status: 200, body: shotArrayJSON())
        let (client, captureStub) = makeClient(stub: stub)

        let results = try await client.listShots(matchID: matchID)

        XCTAssertEqual(results.count, 2, "AC12: must decode two shots")
        XCTAssertEqual(results[0].zone, "baseline_left", "AC12: zone must decode from response")
        XCTAssertEqual(results[0].source, "manual", "AC12: source must decode from response")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC12: request must have been sent")
        XCTAssertEqual(req.httpMethod, "GET", "AC12: method must be GET")
        XCTAssertTrue(req.url?.path.hasSuffix("/shots") == true,
                      "AC12: path must end with /shots, got \(req.url?.path ?? "nil")")
        XCTAssertTrue(req.url?.path.contains("/matches/\(matchID)") == true,
                      "AC12: path must contain /matches/{id}")
        XCTAssertNil(req.httpBody, "AC12: GET must not have an httpBody")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC13: getSummary — GET /matches/{id}/summary → [SummaryEntry]

    func testGetSummaryGetAndParsesArray() async throws {
        let stub = StubTransport.make(status: 200, body: summaryArrayJSON())
        let (client, captureStub) = makeClient(stub: stub)

        let results = try await client.getSummary(matchID: matchID)

        XCTAssertEqual(results.count, 2, "AC13: must decode two summary entries")
        XCTAssertEqual(results[0].zone, "baseline_left", "AC13: zone must decode from response")
        XCTAssertEqual(results[0].count, 3, "AC13: count must decode as Int")

        let req = try XCTUnwrap(captureStub.capturedRequest, "AC13: request must have been sent")
        XCTAssertEqual(req.httpMethod, "GET", "AC13: method must be GET")
        XCTAssertTrue(req.url?.path.hasSuffix("/summary") == true,
                      "AC13: path must end with /summary, got \(req.url?.path ?? "nil")")
        XCTAssertTrue(req.url?.path.contains("/matches/\(matchID)") == true,
                      "AC13: path must contain /matches/{id}")

        // AC14: Bearer header
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)",
                       "AC14: Authorization header must be Bearer <token>")
    }

    // MARK: - AC15: 401 → .invalidCredentials (shared mapError)

    func testStub401ThrowsInvalidCredentials() async throws {
        let stub = StubTransport.make(status: 401, body: #"{"error":"token expired"}"#)
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.listMatches()
            XCTFail("AC15: expected .invalidCredentials to be thrown on 401")
        } catch APIError.invalidCredentials(let msg) {
            XCTAssertEqual(msg, "token expired", "AC15: message must carry the backend text")
        } catch {
            XCTFail("AC15: wrong error type thrown: \(error)")
        }
    }

    // MARK: - AC15: 400 → .validation (shared mapError)

    func testStub400ThrowsValidation() async throws {
        let stub = StubTransport.make(status: 400, body: #"{"error":"invalid zone"}"#)
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.addShots(matchID: matchID, shots: [ShotInput(zone: "baseline_left")])
            XCTFail("AC15: expected .validation to be thrown on 400")
        } catch APIError.validation(let msg) {
            XCTAssertEqual(msg, "invalid zone", "AC15: message must carry the backend text")
        } catch {
            XCTFail("AC15: wrong error type thrown: \(error)")
        }
    }

    // MARK: - AC16: transport throw → .transport (distinct from HTTP status errors)

    func testTransportThrowSurfacesAsTransportError() async throws {
        let stub = StubTransport.throwing(URLError(.notConnectedToInternet))
        let (client, _) = makeClient(stub: stub)

        do {
            _ = try await client.listMatches()
            XCTFail("AC16: expected .transport to be thrown on URLError")
        } catch APIError.transport {
            // Correct: the transport layer error is wrapped, not mapped to an HTTP status case.
            // AC16: this is distinct from .invalidCredentials / .validation / .server
        } catch {
            XCTFail("AC16: wrong error type thrown: \(error)")
        }
    }
}

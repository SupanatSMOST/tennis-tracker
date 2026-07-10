import XCTest
@testable import TennisCore

final class MatchModelDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - AC1: MatchResponse with ended_at: null

    func testMatchResponse_endedAtNull_decodesNil() throws {
        let json = """
        {
            "id": "match-123",
            "user_id": "user-456",
            "court_surface": "clay",
            "created_at": "2026-07-10T10:00:00Z",
            "ended_at": null
        }
        """
        let result = try decoder.decode(MatchResponse.self, from: Data(json.utf8))
        XCTAssertNil(result.endedAt, "ended_at:null should decode to nil")
        XCTAssertEqual(result.id, "match-123")
        XCTAssertEqual(result.userId, "user-456")
        XCTAssertEqual(result.courtSurface, "clay")
        XCTAssertEqual(result.createdAt, "2026-07-10T10:00:00Z")
    }

    // MARK: - AC2: MatchResponse with non-null ended_at

    func testMatchResponse_endedAtString_decodesNonNil() throws {
        let json = """
        {
            "id": "match-123",
            "user_id": "user-456",
            "court_surface": "hard",
            "created_at": "2026-07-10T10:00:00Z",
            "ended_at": "2026-07-10T11:30:00Z"
        }
        """
        let result = try decoder.decode(MatchResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(result.endedAt, "non-null ended_at should decode to a non-nil String")
        XCTAssertEqual(result.endedAt, "2026-07-10T11:30:00Z")
    }

    // MARK: - AC3: ShotResponse decodes all fields as String

    func testShotResponse_decodesAllFields() throws {
        let json = """
        {
            "id": "shot-789",
            "match_id": "match-123",
            "zone": "front_court_left",
            "source": "manual",
            "created_at": "2026-07-10T10:05:00Z"
        }
        """
        let result = try decoder.decode(ShotResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.id, "shot-789")
        XCTAssertEqual(result.matchId, "match-123")
        XCTAssertEqual(result.zone, "front_court_left")
        XCTAssertEqual(result.source, "manual")
        XCTAssertEqual(result.createdAt, "2026-07-10T10:05:00Z")
    }

    // MARK: - AC4: SummaryEntry decodes count as Int

    func testSummaryEntry_decodesCountAsInt() throws {
        let json = """
        {
            "match_id": "match-123",
            "zone": "baseline_right",
            "count": 7
        }
        """
        let result = try decoder.decode(SummaryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(result.matchId, "match-123")
        XCTAssertEqual(result.zone, "baseline_right")
        XCTAssertEqual(result.count, 7)
    }

    // MARK: - AC5: CreateMatchRequest encodes to exactly {"court_surface":"clay"}

    func testCreateMatchRequest_encodesExactlyOneKey() throws {
        let request = CreateMatchRequest(courtSurface: "clay")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertNotNil(dict, "encoded output should be a JSON object")
        XCTAssertEqual(dict?["court_surface"], "clay", "key must be court_surface")
        XCTAssertEqual(dict?.count, 1, "no extra keys should be present")
    }

    // MARK: - AC6: AddShotsRequest encodes zone AND source:"manual" for each element

    func testAddShotsRequest_encodesZoneAndSourceForEachShot() throws {
        let request = AddShotsRequest(shots: [
            ShotInput(zone: "front_court_left"),
            ShotInput(zone: "out_right")
        ])
        let data = try encoder.encode(request)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(top, "encoded output should be a JSON object")
        let shots = top?["shots"] as? [[String: String]]
        XCTAssertNotNil(shots, "shots should be an array of string-keyed objects")
        XCTAssertEqual(shots?.count, 2, "should contain exactly two shot elements")
        XCTAssertEqual(shots?[0]["zone"], "front_court_left")
        XCTAssertEqual(shots?[0]["source"], "manual")
        XCTAssertEqual(shots?[1]["zone"], "out_right")
        XCTAssertEqual(shots?[1]["source"], "manual")
    }

    // MARK: - Regression: non-UUID string id decodes fine

    func testMatchResponse_nonUUIDId_decodesAsString() throws {
        // Guards against a UUID-type regression: if id were typed UUID this would throw.
        let json = """
        {
            "id": "not-a-uuid",
            "user_id": "also-not-a-uuid",
            "court_surface": "grass",
            "created_at": "2026-07-10T09:00:00Z",
            "ended_at": null
        }
        """
        let result = try decoder.decode(MatchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.id, "not-a-uuid")
        XCTAssertEqual(result.userId, "also-not-a-uuid")
    }
}

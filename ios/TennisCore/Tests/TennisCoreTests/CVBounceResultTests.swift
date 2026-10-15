import XCTest
@testable import TennisCore

final class CVBounceResultTests: XCTestCase {
    private func event(zone: CourtZone? = .baselineLeft, status: String = "accepted", id: String = "e1", confidence: Double? = 0.83, imagePoint: CVPoint? = CVPoint(x: 0.5, y: 0.7), timestamp: Int64 = 500) -> CVBounceEvent {
        CVBounceEvent(eventId: id, timestampMs: timestamp, imagePoint: imagePoint, courtPoint: CVPoint(x: 0.4, y: 0.8), zone: zone, confidence: confidence, reviewStatus: status)
    }
    private func result(events: [CVBounceEvent]) -> CVBounceResult {
        CVBounceResult(matchId: "match-1", video: CVVideoMetadata(durationMs: 10_000, width: 1920, height: 1080, fps: 60), calibrationId: "cal-1", model: CVModelMetadata(name: "tracknet", version: "candidate-1", runtime: "coreml"), events: events)
    }
    func testAllCanonicalZonesRoundTripAndValidate() throws {
        XCTAssertEqual(Set(CourtZone.allCases.map(\.rawValue)), Set(["front_court_left", "front_court_right", "baseline_left", "baseline_right", "out_left", "out_right"]))
        for zone in CourtZone.allCases {
            let value = result(events: [event(zone: zone)])
            try value.validate()
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(CVBounceResult.self, from: data), value)
        }
    }
    func testRejectsNonCanonicalZoneOnDecode() {
        let data = Data(#"{"schema_version":"1.0","match_id":"match-1","video":{"duration_ms":10000,"width":1920,"height":1080,"fps":60},"calibration_id":"cal-1","model":{"name":"tracknet","version":"v1","runtime":"coreml"},"events":[{"event_id":"e1","event_type":"bounce","timestamp_ms":500,"image_point":{"x":0.5,"y":0.5},"court_point":null,"zone":"out_behind","confidence":0.8,"review_status":"accepted"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CVBounceResult.self, from: data))
    }
    func testZeroBouncesValid() throws { let value = result(events: []); try value.validate(); XCTAssertTrue(value.acceptedEvents.isEmpty) }
    func testRejectsOutOfBoundsPointConfidenceAndTimestamp() {
        for invalid in [event(imagePoint: CVPoint(x: 1.01, y: 0.4)), event(confidence: 1.2), event(timestamp: 10_001)] {
            XCTAssertThrowsError(try result(events: [invalid]).validate())
        }
    }
    func testRejectedAndUnreviewedNotCounted() throws {
        let value = result(events: [event(status: "rejected"), event(status: "needs_review", id: "e2"), event(status: "unresolved", id: "e3")])
        try value.validate()
        XCTAssertTrue(value.acceptedEvents.isEmpty)
    }
    func testInvalidReviewStatusRejected() {
        XCTAssertThrowsError(try result(events: [event(status: "approved")]).validate())
    }
}

import XCTest
@testable import TennisCore

final class CVBounceResultTests: XCTestCase {
    func testSharedGoldenSevenZoneFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/golden_bounce_events_7zones.json")
        let data = try Data(contentsOf: url)
        let result = try JSONDecoder().decode(CVBounceResult.self, from: data)
        try result.validate()
        XCTAssertEqual(Set(result.events.compactMap { $0.zone?.rawValue }), Set(CourtZone.allCases.map(\.rawValue)))
        XCTAssertEqual(result.acceptedEvents.count, 7)
    }

    func testReviewAuthorityFiltersNonAcceptedStatuses() throws {
        let data = Data(#"{"schema_version":"1.0","match_id":"m","video":{"duration_ms":1000,"width":10,"height":10,"fps":30},"calibration_id":"c","model":{"name":"m","version":"1","runtime":"test"},"events":[{"event_id":"a","event_type":"bounce","timestamp_ms":1,"image_point":null,"court_point":null,"zone":"out_behind","confidence":null,"review_status":"accepted"},{"event_id":"b","event_type":"bounce","timestamp_ms":2,"image_point":null,"court_point":null,"zone":"out_behind","confidence":null,"review_status":"corrected"},{"event_id":"c","event_type":"bounce","timestamp_ms":3,"image_point":null,"court_point":null,"zone":"out_behind","confidence":null,"review_status":"needs_review"},{"event_id":"d","event_type":"bounce","timestamp_ms":4,"image_point":null,"court_point":null,"zone":"out_behind","confidence":null,"review_status":"unresolved"},{"event_id":"e","event_type":"bounce","timestamp_ms":5,"image_point":null,"court_point":null,"zone":"out_behind","confidence":null,"review_status":"rejected"}]}"#.utf8)
        let result = try JSONDecoder().decode(CVBounceResult.self, from: data)
        try result.validate()
        XCTAssertEqual(result.acceptedEvents.map(\.eventId), ["a", "b"])
    }
}

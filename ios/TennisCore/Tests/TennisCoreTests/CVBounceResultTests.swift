import XCTest
@testable import TennisCore

final class CVBounceResultTests: XCTestCase {
    private func fixture(events: [CVBounceEvent]? = nil) -> CVBounceResult {
        CVBounceResult(matchId:"match-1", video:CVVideoMetadata(durationMs:10_000,width:1920,height:1080,fps:60), calibrationId:"cal-1", model:CVModelMetadata(name:"tracknet",version:"candidate-1",runtime:"coreml"), events:events ?? [CVBounceEvent(eventId:"e1",timestampMs:500,imagePoint:CVPoint(x:0.5,y:0.7),courtPoint:CVPoint(x:0.4,y:0.8),zone:"baseline_left",confidence:0.83,reviewStatus:"accepted")])
    }
    func testJSONRoundTripAndCodingKeys() throws { let value=fixture(); try value.validate(); let data=try JSONEncoder().encode(value); let json=try XCTUnwrap(String(data:data,encoding:.utf8)); XCTAssertTrue(json.contains("schema_version")); XCTAssertTrue(json.contains("timestamp_ms")); XCTAssertEqual(try JSONDecoder().decode(CVBounceResult.self,from:data),value) }
    func testZeroBouncesValid() throws { let value=fixture(events:[]); try value.validate(); XCTAssertTrue(value.acceptedEvents.isEmpty) }
    func testRejectsOutOfBoundsAndNoisyConfidence() { for event in [CVBounceEvent(eventId:"bad",timestampMs:1,imagePoint:CVPoint(x:1.01,y:0.4),courtPoint:nil,zone:nil,confidence:0.2,reviewStatus:"needs_review"), CVBounceEvent(eventId:"bad",timestampMs:1,imagePoint:nil,courtPoint:nil,zone:nil,confidence:1.2,reviewStatus:"needs_review")] { XCTAssertThrowsError(try fixture(events:[event]).validate()) } }
    func testUnreviewedNotCountedAndZoneTaxonomyChecked() throws { let pending=CVBounceEvent(eventId:"p",timestampMs:1,imagePoint:nil,courtPoint:nil,zone:"baseline_left",confidence:nil,reviewStatus:"needs_review"); XCTAssertTrue(fixture(events:[pending]).acceptedEvents.isEmpty); let bad=CVBounceEvent(eventId:"z",timestampMs:1,imagePoint:nil,courtPoint:nil,zone:"mystery",confidence:nil,reviewStatus:"accepted"); XCTAssertThrowsError(try fixture(events:[bad]).validate()) }
}

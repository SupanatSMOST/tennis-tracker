import XCTest
@testable import TennisCore

final class CVBounceResultTests: XCTestCase {
    private func event(zone: CourtZone = .baselineLeft) -> CVBounceEvent {
        CVBounceEvent(eventId: "e1", timestampMs: 500, imagePoint: CVPoint(x: 0.5, y: 0.7), courtPoint: CVPoint(x: 0.4, y: 0.8), zone: zone, confidence: 0.83, reviewStatus: "accepted")
    }
    private func fixture(events: [CVBounceEvent]) -> CVBounceResult {
        CVBounceResult(matchId: "match-1", video: CVVideoMetadata(durationMs: 10_000, width: 1920, height: 1080, fps: 60), calibrationId: "cal-1", model: CVModelMetadata(name: "tracknet", version: "candidate-1", runtime: "coreml"), events: events)
    }
    func testAllCanonicalZonesIncludingOutBehind() throws {
        XCTAssertEqual(Set(CourtZone.allCases.map(\\.rawValue)), Set(["front_court_left", "front_court_right", "baseline_left", "baseline_right", "out_left", "out_right", "out_behind"]))
        for zone in CourtZone.allCases {
            let value = fixture(events: [event(zone: zone)])
            try value.validate()
            XCTAssertEqual(try JSONDecoder().decode(CVBounceResult.self, from: JSONEncoder().encode(value)), value)
        }
    }
    func testZeroBouncesValid() throws {
        let value = fixture(events: [])
        try value.validate()
        XCTAssertTrue(value.acceptedEvents.isEmpty)
    }
    func testRejectedAndUnreviewedEventsNotMapped() throws {
        let pending = CVBounceEvent(eventId: "p", timestampMs: 1, imagePoint: nil, courtPoint: nil, zone: .outBehind, confidence: nil, reviewStatus: "needs_review")
        let rejected = CVBounceEvent(eventId: "r", timestampMs: 2, imagePoint: nil, courtPoint: nil, zone: .outBehind, confidence: nil, reviewStatus: "rejected")
        let value = fixture(events: [pending, rejected])
        try value.validate()
        XCTAssertTrue(value.acceptedEvents.isEmpty)
    }
}

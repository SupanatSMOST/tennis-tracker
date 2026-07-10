/// RecordSessionViewModelTests — Task 6 tests for RecordSessionViewModel.
///
/// AC24 (load-bearing): a shot is NEVER dropped on a transport/network error.
///   record(zone:) with a throwing stub → shots.count == 1, status == .failed, count == 1.
///
/// AC25 happy path: N record() calls produce N shots in tap order, all .confirmed.
///   endMatch() calls client.endMatch(id:) with the correct matchID and exposes the result.
///
/// endMatch error path: a throwing stub surfaces endMatchError, no crash.

import XCTest
@testable import TennisCore

final class RecordSessionViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let token   = "test-bearer-token"
    private let matchID = "match-record-xyz"

    private func makeViewModel(stub: StubTransport) -> (RecordSessionViewModel, StubTransport) {
        let store = InMemoryTokenStore()
        store.set(token)
        let client = MatchClient(config: APIConfig(), transport: stub, tokenStore: store)
        let vm = RecordSessionViewModel(client: client, matchID: matchID)
        return (vm, stub)
    }

    private func endedMatchJSON() -> String {
        """
        {"id":"\(matchID)","user_id":"u1","court_surface":"clay","created_at":"2026-07-05T10:00:00Z","ended_at":"2026-07-05T11:30:00Z"}
        """
    }

    // MARK: - AC24 (load-bearing): shot retained as .failed on transport error

    func testRecord_transportError_shotRetainedAsFailed() async {
        let stub = StubTransport.throwing(URLError(.notConnectedToInternet))
        let (vm, _) = makeViewModel(stub: stub)

        await vm.record(zone: "baseline_left")  // transport throws — must not crash

        XCTAssertEqual(vm.shots.count, 1,
                       "AC24: shots.count must be 1 — the shot must NOT be dropped on transport error")
        XCTAssertEqual(vm.shots[0].zone, "baseline_left",
                       "AC24: shot zone must be preserved")
        XCTAssertEqual(vm.shots[0].status, .failed,
                       "AC24: shot status must be .failed after transport error")
        XCTAssertEqual(vm.count, 1,
                       "AC24: count must equal 1 — includes failed shots")
    }

    // MARK: - AC25: N taps produce N shots in order, all .confirmed

    func testRecord_happyPath_nShotsInOrderAllConfirmed() async {
        let stub = StubTransport.make(status: 200, body: #"{"count":1}"#)
        let (vm, _) = makeViewModel(stub: stub)

        let zones = ["baseline_left", "front_court_right", "out_left", "baseline_right"]

        // Await sequentially to preserve tap order.
        for zone in zones {
            await vm.record(zone: zone)
        }

        XCTAssertEqual(vm.count, zones.count,
                       "AC25: count must equal the number of taps")
        XCTAssertEqual(vm.shots.count, zones.count,
                       "AC25: shots array length must equal the number of taps")
        XCTAssertEqual(vm.shots.map(\.zone), zones,
                       "AC25: shots must preserve tap order exactly")
        for (i, shot) in vm.shots.enumerated() {
            XCTAssertEqual(shot.status, .confirmed,
                           "AC25: shot[\(i)] must be .confirmed on success")
        }
    }

    // MARK: - AC25: endMatch exposes the returned MatchResponse with the correct id

    func testEndMatch_success_exposesEndedMatch() async throws {
        let stub = StubTransport.make(status: 200, body: endedMatchJSON())
        let (vm, captureStub) = makeViewModel(stub: stub)

        await vm.endMatch()

        let ended = try XCTUnwrap(vm.endedMatch,
                                  "AC25: endedMatch must be set after a successful endMatch()")
        XCTAssertEqual(ended.id, matchID,
                       "AC25: endedMatch.id must equal the matchID the VM was initialised with")
        XCTAssertNotNil(ended.endedAt,
                        "AC25: endedMatch.endedAt must be non-nil (match was ended)")

        // Verify the client called the correct path (contains matchID and ends with /end)
        let req = try XCTUnwrap(captureStub.capturedRequest,
                                "AC25: a request must have been sent to the transport")
        XCTAssertTrue(req.url?.path.contains(matchID) == true,
                      "AC25: request path must contain the matchID")
        XCTAssertTrue(req.url?.path.hasSuffix("/end") == true,
                      "AC25: request path must end with /end")
        XCTAssertNil(vm.endMatchError,
                     "AC25: endMatchError must be nil on success")
    }

    // MARK: - endMatch error path: endMatchError set, no crash

    func testEndMatch_throwingStub_setsEndMatchError() async {
        let stub = StubTransport.throwing(URLError(.notConnectedToInternet))
        let (vm, _) = makeViewModel(stub: stub)

        await vm.endMatch()  // must not crash

        XCTAssertNotNil(vm.endMatchError,
                        "endMatch error path: endMatchError must be set when the transport throws")
        XCTAssertNil(vm.endedMatch,
                     "endMatch error path: endedMatch must remain nil on failure")
    }
}

/// MatchSummaryViewModelTests — Task 5 tests for MatchSummaryViewModel.
///
/// AC27: load() with a stubbed summary populates entries with the per-zone counts.
///       A stubbed throwing transport surfaces its error as loadError (no crash).

import XCTest
@testable import TennisCore

final class MatchSummaryViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let token   = "test-bearer-token"
    private let matchID = "match-summary-abc"

    private func makeViewModel(stub: StubTransport) -> MatchSummaryViewModel {
        let store = InMemoryTokenStore()
        store.set(token)
        let client = MatchClient(config: APIConfig(), transport: stub, tokenStore: store)
        return MatchSummaryViewModel(client: client, matchID: matchID)
    }

    private func summaryJSON() -> String {
        """
        [
          {"match_id":"\(matchID)","zone":"baseline_left","count":5},
          {"match_id":"\(matchID)","zone":"out_right","count":2}
        ]
        """
    }

    // MARK: - AC27: happy path — entries populated

    func testLoad_populatesEntries() async {
        let stub = StubTransport.make(status: 200, body: summaryJSON())
        let vm = makeViewModel(stub: stub)

        await vm.load()

        XCTAssertEqual(vm.entries.count, 2,
                       "AC27: load() must populate entries with the decoded summary array")
        XCTAssertEqual(vm.entries[0].zone, "baseline_left",
                       "AC27: first entry zone must decode correctly")
        XCTAssertEqual(vm.entries[0].count, 5,
                       "AC27: first entry count must decode as Int")
        XCTAssertEqual(vm.entries[1].zone, "out_right",
                       "AC27: second entry zone must decode correctly")
        XCTAssertEqual(vm.entries[1].count, 2,
                       "AC27: second entry count must decode as Int")
        XCTAssertNil(vm.loadError,
                     "AC27: loadError must be nil on success")
    }

    // MARK: - AC27: error path — loadError set, no crash

    func testLoad_throwingStub_setsLoadErrorAndEntriesStaysEmpty() async {
        let stub = StubTransport.throwing(URLError(.notConnectedToInternet))
        let vm = makeViewModel(stub: stub)

        await vm.load()  // must not crash

        XCTAssertNotNil(vm.loadError,
                        "AC27: loadError must be set when the transport throws")
        XCTAssertTrue(vm.entries.isEmpty,
                      "AC27: entries must remain empty when load fails")
    }
}

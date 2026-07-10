/// MatchListViewModelTests — Task 5 tests for MatchListViewModel.
///
/// AC26: isActive(_ m) returns true for a match with endedAt==nil, false for non-nil endedAt.
/// OQ-5: load() sorts matches most-recent-first (descending createdAt).
/// Error path: load() on a throwing stub sets loadError, matches stays empty.

import XCTest
@testable import TennisCore

final class MatchListViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let token = "test-bearer-token"

    private func makeViewModel(stub: StubTransport) -> MatchListViewModel {
        let store = InMemoryTokenStore()
        store.set(token)
        let client = MatchClient(config: APIConfig(), transport: stub, tokenStore: store)
        return MatchListViewModel(client: client)
    }

    /// Two-element JSON array with DIFFERENT ids and DIFFERENT createdAt timestamps.
    /// Ordered older-first in the JSON so a no-op sort would leave them in wrong order.
    private func twoMatchesJSON() -> String {
        """
        [
          {"id":"m-older","user_id":"u1","court_surface":"clay","created_at":"2026-07-01T10:00:00Z","ended_at":null},
          {"id":"m-newer","user_id":"u1","court_surface":"hard","created_at":"2026-07-05T10:00:00Z","ended_at":"2026-07-05T11:00:00Z"}
        ]
        """
    }

    // MARK: - AC26: isActive routing helper

    func testIsActive_returnsTrueForNilEndedAt() async throws {
        let stub = StubTransport.make(status: 200, body: twoMatchesJSON())
        let vm = makeViewModel(stub: stub)

        await vm.load()

        // Find the match without an ended_at — must be reported as active
        let active = try XCTUnwrap(vm.matches.first { $0.endedAt == nil },
                                   "AC26: expected at least one active match in the loaded list")
        XCTAssertTrue(vm.isActive(active),
                      "AC26: isActive must return true for a match with endedAt == nil")
    }

    func testIsActive_returnsFalseForNonNilEndedAt() async throws {
        let stub = StubTransport.make(status: 200, body: twoMatchesJSON())
        let vm = makeViewModel(stub: stub)

        await vm.load()

        // Find the match with a non-nil ended_at — must NOT be reported as active
        let ended = try XCTUnwrap(vm.matches.first { $0.endedAt != nil },
                                  "AC26: expected at least one ended match in the loaded list")
        XCTAssertFalse(vm.isActive(ended),
                       "AC26: isActive must return false for a match with non-nil endedAt")
    }

    // MARK: - OQ-5: sort order (most-recent-first)

    func testLoad_sortsMostRecentFirst() async {
        // Feed older-first in the stub; after load() matches[0] must be the newer one.
        let stub = StubTransport.make(status: 200, body: twoMatchesJSON())
        let vm = makeViewModel(stub: stub)

        await vm.load()

        XCTAssertEqual(vm.matches.count, 2, "OQ-5: both matches must be loaded")
        XCTAssertEqual(vm.matches[0].id, "m-newer",
                       "OQ-5: most-recent match (2026-07-05) must be first after sorting")
        XCTAssertEqual(vm.matches[1].id, "m-older",
                       "OQ-5: older match (2026-07-01) must be second after sorting")
    }

    // MARK: - Error path: transport failure

    func testLoad_throwingStub_setsLoadErrorAndMatchesStaysEmpty() async {
        let stub = StubTransport.throwing(URLError(.notConnectedToInternet))
        let vm = makeViewModel(stub: stub)

        await vm.load()  // must not crash

        XCTAssertNotNil(vm.loadError,
                        "Error path: loadError must be set when the transport throws")
        XCTAssertTrue(vm.matches.isEmpty,
                      "Error path: matches must remain empty when load fails")
    }
}

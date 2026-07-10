/// MatchSummaryViewModel — @Observable VM for the match summary screen.
///
/// Loads per-zone shot counts for a specific match via `getSummary(matchID:)`.
/// A thrown error is stored in `loadError` — never crash (AC27).

import Foundation
import Observation

@Observable
public final class MatchSummaryViewModel {

    // MARK: - State

    /// Per-zone shot count entries for the match.
    public var entries: [SummaryEntry] = []

    /// A human-readable error message from the last failed load, if any.
    public var loadError: String?

    // MARK: - Dependencies

    private let client: MatchClient
    private let matchID: String

    // MARK: - Init

    public init(client: MatchClient, matchID: String) {
        self.client = client
        self.matchID = matchID
    }

    // MARK: - Actions

    /// Loads the summary for the match.
    ///
    /// On success: `entries` is updated, `loadError` is cleared.
    /// On failure: `loadError` is set, `entries` is left unchanged (AC27).
    public func load() async {
        do {
            let result = try await client.getSummary(matchID: matchID)
            entries = result
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }

    // MARK: - Private

    private func errorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError, let msg = apiError.backendMessage {
            return msg
        }
        return error.localizedDescription
    }
}

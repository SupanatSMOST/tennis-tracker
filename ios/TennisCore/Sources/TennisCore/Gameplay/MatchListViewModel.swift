/// MatchListViewModel — @Observable VM for the match list screen.
///
/// Loads all matches for the authenticated user, sorts them most-recent-first
/// (OQ-5: createdAt string compare descending, valid for ISO timestamps).
/// Exposes `create(surface:)` to create a new match and surfaces the result
/// via `createdMatch` for routing.
/// All errors are stored in `loadError` — never crash (AC26/AC27 contract).

import Foundation
import Observation

@Observable
public final class MatchListViewModel {

    // MARK: - State

    /// Loaded matches, sorted most-recent-first by createdAt (OQ-5).
    public var matches: [MatchResponse] = []

    /// A human-readable error message from the last failed operation, if any.
    public var loadError: String?

    /// The newly created match from the last `create(surface:)` call.
    public var createdMatch: MatchResponse?

    // MARK: - Dependencies

    private let client: MatchClient

    // MARK: - Init

    public init(client: MatchClient) {
        self.client = client
    }

    // MARK: - Actions

    /// Loads all matches from the server and sorts them most-recent-first.
    ///
    /// On success: `matches` is updated, `loadError` is cleared.
    /// On failure: `loadError` is set, `matches` is left unchanged (AC26).
    public func load() async {
        do {
            let raw = try await client.listMatches()
            matches = raw.sorted { $0.createdAt > $1.createdAt }
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }

    /// Creates a new match with the given court surface.
    ///
    /// On success: `createdMatch` holds the new `MatchResponse`.
    /// On failure: `loadError` is set.
    public func create(surface: String) async {
        do {
            let match = try await client.createMatch(surface: surface)
            createdMatch = match
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }

    // MARK: - Routing helper

    /// Returns true when the match is still active (no end timestamp).
    /// Routes to session view (true) vs summary view (false) — AC26.
    public func isActive(_ m: MatchResponse) -> Bool {
        m.endedAt == nil
    }

    // MARK: - Private

    private func errorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError, let msg = apiError.backendMessage {
            return msg
        }
        return error.localizedDescription
    }
}

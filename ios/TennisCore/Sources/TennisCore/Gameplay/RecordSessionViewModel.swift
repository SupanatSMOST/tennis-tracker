/// RecordSessionViewModel — @Observable VM for the in-session recording screen.
///
/// Tracks every tapped shot locally with `LocalShot` and reflects network
/// confirmation status (pending / confirmed / failed).
///
/// AC24 (load-bearing): a shot is NEVER removed on a transport error.
/// `record(zone:)` appends the shot as `.pending` BEFORE the network call;
/// on any thrown error the element is marked `.failed` and stays in `shots`.
///
/// AC25: `endMatch()` calls `client.endMatch(id:)` and stores the returned
/// `MatchResponse` in `endedMatch`; on error stores a message — never crashes.

import Foundation
import Observation

// MARK: - Supporting types

/// The synchronisation status of a locally recorded shot.
public enum ShotStatus: Equatable {
    case pending
    case confirmed
    case failed
}

/// A shot recorded locally during an active session.
public struct LocalShot: Identifiable {
    public let id: UUID
    public let zone: String
    public var status: ShotStatus

    public init(id: UUID = UUID(), zone: String, status: ShotStatus = .pending) {
        self.id = id
        self.zone = zone
        self.status = status
    }
}

// MARK: - ViewModel

@Observable
public final class RecordSessionViewModel {

    // MARK: - State

    /// All locally recorded shots, in tap order.
    /// Never shrinks — shots marked `.failed` are retained (AC24).
    public private(set) var shots: [LocalShot] = []

    /// The ended match returned by `client.endMatch(id:)` on success.
    public var endedMatch: MatchResponse?

    /// A human-readable error from the last failed `endMatch()` call, if any.
    public var endMatchError: String?

    // MARK: - Dependencies

    private let client: MatchClient
    private let matchID: String

    // MARK: - Init

    public init(client: MatchClient, matchID: String) {
        self.client = client
        self.matchID = matchID
    }

    // MARK: - Actions

    /// Records a shot for the given zone.
    ///
    /// 1. Appends a `.pending` `LocalShot` to `shots` immediately (optimistic).
    /// 2. Calls `addShots(matchID:shots:)`.
    /// 3. On success: marks the element `.confirmed`.
    /// 4. On failure: marks the element `.failed` — the shot is never removed (AC24).
    public func record(zone: String) async {
        let shot = LocalShot(id: UUID(), zone: zone, status: .pending)
        shots.append(shot)
        let capturedID = shot.id

        do {
            _ = try await client.addShots(matchID: matchID, shots: [ShotInput(zone: zone)])
            if let idx = shots.firstIndex(where: { $0.id == capturedID }) {
                shots[idx].status = .confirmed
            }
        } catch {
            if let idx = shots.firstIndex(where: { $0.id == capturedID }) {
                shots[idx].status = .failed
            }
        }
    }

    /// Ends the active match.
    ///
    /// On success: `endedMatch` holds the returned `MatchResponse`.
    /// On failure: `endMatchError` is set — never crashes (AC25).
    public func endMatch() async {
        do {
            let match = try await client.endMatch(id: matchID)
            endedMatch = match
            endMatchError = nil
        } catch {
            endMatchError = errorMessage(error)
        }
    }

    // MARK: - Derived

    /// Total number of recorded shots (including pending and failed).
    public var count: Int { shots.count }

    /// Returns the most recent `n` shots, in tap order.
    /// If `n` exceeds the total, all shots are returned. Mirrors `Array.suffix` semantics.
    public func lastN(_ n: Int) -> [LocalShot] {
        Array(shots.suffix(n))
    }

    // MARK: - Private

    private func errorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError, let msg = apiError.backendMessage {
            return msg
        }
        return error.localizedDescription
    }
}

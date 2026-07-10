/// MatchClient — gameplay API calls for the Tennis Shot Tracker.
///
/// Peer to APIClient; built on the shared RequestExecutor so no request
/// machinery is duplicated (A-3 / FR-M3).
///
/// All seven methods send `Authorization: Bearer <token>` via
/// `executor.authorizedRequest` — throws `.noToken` if absent (AC14).
/// Success is any 2xx (`(200...299).contains`) — POST codes are unpinned
/// in the API contract (plan §2.1).
/// Non-2xx → `executor.mapError` (400→validation, 401→invalidCredentials,
/// else→server; 404 falls through to server per OQ-4/A-8).
/// Transport errors surface as `.transport` (AC16) from `executor.performSend`.

import Foundation

public final class MatchClient {
    private let executor: RequestExecutor

    public init(config: APIConfig, transport: HTTPTransport, tokenStore: TokenStore) {
        self.executor = RequestExecutor(config: config, transport: transport, tokenStore: tokenStore)
    }

    // MARK: - Match lifecycle

    /// Creates a new match with the given court surface.
    /// POST /matches — body `{"court_surface":"..."}` (AC7).
    public func createMatch(surface: String) async throws -> MatchResponse {
        let body = CreateMatchRequest(courtSurface: surface)
        let request = try executor.authorizedRequest(method: "POST", path: "/matches", body: body)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode(MatchResponse.self, from: data)
    }

    /// Returns all matches for the authenticated user.
    /// GET /matches (AC8).
    public func listMatches() async throws -> [MatchResponse] {
        let request = try executor.authorizedRequest(method: "GET", path: "/matches", body: nil as EmptyBody?)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode([MatchResponse].self, from: data)
    }

    /// Returns a single match by id.
    /// GET /matches/{id} (AC9).
    public func getMatch(id: String) async throws -> MatchResponse {
        let request = try executor.authorizedRequest(method: "GET", path: "/matches/\(id)", body: nil as EmptyBody?)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode(MatchResponse.self, from: data)
    }

    /// Ends an active match (sets ended_at on the server).
    /// POST /matches/{id}/end — no body (AC10).
    public func endMatch(id: String) async throws -> MatchResponse {
        let request = try executor.authorizedRequest(method: "POST", path: "/matches/\(id)/end", body: nil as EmptyBody?)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode(MatchResponse.self, from: data)
    }

    // MARK: - Shots

    /// Posts one or more shots for a match; returns the count of shots stored.
    /// POST /matches/{id}/shots — body `{"shots":[...]}` → `{"count":N}` (AC11).
    public func addShots(matchID: String, shots: [ShotInput]) async throws -> Int {
        let body = AddShotsRequest(shots: shots)
        let request = try executor.authorizedRequest(method: "POST", path: "/matches/\(matchID)/shots", body: body)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        let result = try JSONDecoder().decode(CountResponse.self, from: data)
        return result.count
    }

    /// Returns all recorded shots for a match.
    /// GET /matches/{id}/shots (AC12).
    public func listShots(matchID: String) async throws -> [ShotResponse] {
        let request = try executor.authorizedRequest(method: "GET", path: "/matches/\(matchID)/shots", body: nil as EmptyBody?)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode([ShotResponse].self, from: data)
    }

    /// Returns the per-zone shot counts for a match.
    /// GET /matches/{id}/summary (AC13).
    public func getSummary(matchID: String) async throws -> [SummaryEntry] {
        let request = try executor.authorizedRequest(method: "GET", path: "/matches/\(matchID)/summary", body: nil as EmptyBody?)
        let (data, response) = try await executor.performSend(request)
        guard (200...299).contains(response.statusCode) else {
            throw try executor.mapError(data: data, status: response.statusCode)
        }
        return try JSONDecoder().decode([SummaryEntry].self, from: data)
    }

    // MARK: - Private types

    /// Inline decode type for the `POST /matches/{id}/shots` response `{"count":N}`.
    /// Not a public DTO — the public return type is `Int` (plan §2.1).
    private struct CountResponse: Decodable {
        let count: Int
    }
}

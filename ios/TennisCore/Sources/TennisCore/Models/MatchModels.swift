/// Codable DTOs for the Tennis Shot Tracker match / shot / summary endpoints.
/// All UUID-bearing fields decode to Swift `String`, never `UUID` (A-4).
/// Snake-case JSON keys map via explicit CodingKeys (mirrors AuthModels.swift style).
/// Timestamps are opaque `String` — no dateDecodingStrategy (A-7).

// MARK: - Response DTOs

public struct MatchResponse: Decodable {
    public let id: String
    public let userId: String
    public let courtSurface: String
    public let createdAt: String
    public let endedAt: String?          // null → nil (active); non-null (ended) — AC1/AC2

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case courtSurface = "court_surface"
        case createdAt    = "created_at"
        case endedAt      = "ended_at"
    }
}

public struct ShotResponse: Decodable {
    public let id: String
    public let matchId: String
    public let zone: String
    public let source: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case matchId   = "match_id"
        case zone
        case source
        case createdAt = "created_at"
    }
}

public struct SummaryEntry: Decodable {
    public let matchId: String
    public let zone: String
    public let count: Int               // decoded as Int — AC4

    enum CodingKeys: String, CodingKey {
        case matchId = "match_id"
        case zone
        case count
    }
}

// MARK: - Request DTOs

public struct CreateMatchRequest: Encodable {
    public let courtSurface: String

    public init(courtSurface: String) {
        self.courtSurface = courtSurface
    }

    enum CodingKeys: String, CodingKey {
        case courtSurface = "court_surface"
    }
}

public struct ShotInput: Encodable {
    public let zone: String
    public let source: String           // stored property — ensures it encodes (AC6)

    public init(zone: String, source: String = "manual") {
        self.zone = zone
        self.source = source
    }
    // No CodingKeys needed — both property names match JSON keys exactly.
}

public struct AddShotsRequest: Encodable {
    public let shots: [ShotInput]

    public init(shots: [ShotInput]) {
        self.shots = shots
    }
    // No CodingKeys needed — "shots" matches the JSON key.
}

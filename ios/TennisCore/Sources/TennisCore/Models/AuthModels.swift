/// Response models for the Tennis Shot Tracker auth endpoints.
/// All `user_id` JSON keys map to `userId: String` via CodingKeys.
/// CRITICAL: userId is typed String, never UUID — the backend serialises via .String().

public struct SignupResponse: Codable {
    public let userId: String
    public let username: String
    public let token: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case token
    }
}

public struct LoginResponse: Codable {
    public let token: String
}

public struct MeResponse: Codable {
    public let userId: String
    public let username: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
    }
}

public struct ErrorResponse: Codable {
    public let error: String
}

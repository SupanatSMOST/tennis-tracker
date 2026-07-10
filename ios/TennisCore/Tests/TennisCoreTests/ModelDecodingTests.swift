import XCTest
@testable import TennisCore

final class ModelDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - AC1: SignupResponse

    func testSignupResponse_decodesAllFields() throws {
        let json = #"{"user_id":"abc","username":"u","token":"t"}"#
        let result = try decoder.decode(SignupResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.userId, "abc")
        XCTAssertEqual(result.username, "u")
        XCTAssertEqual(result.token, "t")
    }

    func testSignupResponse_missingField_throws() {
        let json = #"{"user_id":"abc","username":"u"}"# // missing token
        XCTAssertThrowsError(
            try decoder.decode(SignupResponse.self, from: Data(json.utf8))
        )
    }

    // MARK: - AC2: LoginResponse

    func testLoginResponse_decodesToken() throws {
        let json = #"{"token":"t"}"#
        let result = try decoder.decode(LoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.token, "t")
    }

    func testLoginResponse_missingToken_throws() {
        let json = #"{}"#
        XCTAssertThrowsError(
            try decoder.decode(LoginResponse.self, from: Data(json.utf8))
        )
    }

    // MARK: - AC3: MeResponse

    func testMeResponse_decodesAllFields() throws {
        let json = #"{"user_id":"abc","username":"u"}"#
        let result = try decoder.decode(MeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.userId, "abc")
        XCTAssertEqual(result.username, "u")
    }

    func testMeResponse_missingField_throws() {
        let json = #"{"user_id":"abc"}"# // missing username
        XCTAssertThrowsError(
            try decoder.decode(MeResponse.self, from: Data(json.utf8))
        )
    }

    // MARK: - AC4: ErrorResponse

    func testErrorResponse_decodesError() throws {
        let json = #"{"error":"msg"}"#
        let result = try decoder.decode(ErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.error, "msg")
    }

    func testErrorResponse_missingError_throws() {
        let json = #"{}"#
        XCTAssertThrowsError(
            try decoder.decode(ErrorResponse.self, from: Data(json.utf8))
        )
    }

    // MARK: - UUID regression guard

    func testSignupResponse_nonUUID_userIdDecodesAsString() throws {
        // Proves userId is typed String, not UUID — non-UUID strings must round-trip cleanly.
        let json = #"{"user_id":"not-a-uuid","username":"u","token":"t"}"#
        let result = try decoder.decode(SignupResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.userId, "not-a-uuid")
    }

    func testMeResponse_nonUUID_userIdDecodesAsString() throws {
        let json = #"{"user_id":"not-a-uuid","username":"u"}"#
        let result = try decoder.decode(MeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(result.userId, "not-a-uuid")
    }

    // MARK: - Request encoders

    func testSignupRequest_encodesUsernameAndPassword() throws {
        let request = SignupRequest(username: "alice", password: "secret")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertNotNil(dict, "encoded output should be a JSON object")
        XCTAssertEqual(dict?["username"], "alice")
        XCTAssertEqual(dict?["password"], "secret")
        XCTAssertEqual(dict?.count, 2, "no extra keys should be present")
    }

    func testLoginRequest_encodesUsernameAndPassword() throws {
        let request = LoginRequest(username: "bob", password: "pass123")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertNotNil(dict, "encoded output should be a JSON object")
        XCTAssertEqual(dict?["username"], "bob")
        XCTAssertEqual(dict?["password"], "pass123")
        XCTAssertEqual(dict?.count, 2, "no extra keys should be present")
    }
}

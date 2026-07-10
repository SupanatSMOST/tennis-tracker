import XCTest
@testable import TennisCore

final class PasswordValidatorTests: XCTestCase {

    // MARK: - Too Short

    func testEmptyString_isTooShort() {
        XCTAssertEqual(PasswordValidator.validate(""), .tooShort)
    }

    func testSevenCharASCII_isTooShort() {
        let pw = "abcdefg"
        XCTAssertEqual(pw.count, 7, "fixture must be exactly 7 graphemes")
        XCTAssertEqual(PasswordValidator.validate(pw), .tooShort)
    }

    // MARK: - Valid (lower boundary)

    func testEightCharASCII_isValid() {
        // 8 ASCII chars = 8 graphemes and 8 UTF-8 bytes — both rules satisfied.
        let pw = "password"
        XCTAssertEqual(pw.count, 8, "fixture must be exactly 8 graphemes")
        XCTAssertEqual(pw.utf8.count, 8, "fixture must be exactly 8 UTF-8 bytes")
        XCTAssertEqual(PasswordValidator.validate(pw), .valid)
    }

    func testExactlyEightChars_isValid_lowerBoundaryInclusive() {
        let pw = "12345678"
        XCTAssertEqual(pw.count, 8)
        XCTAssertEqual(PasswordValidator.validate(pw), .valid)
    }

    // MARK: - Valid (upper boundary)

    func testExactly72Bytes_isValid() {
        // 72 ASCII chars: count == 72 and utf8.count == 72. Both at or under the limits.
        let pw = String(repeating: "a", count: 72)
        XCTAssertEqual(pw.count, 72, "fixture must be 72 graphemes")
        XCTAssertEqual(pw.utf8.count, 72, "fixture must be exactly 72 UTF-8 bytes")
        XCTAssertEqual(PasswordValidator.validate(pw), .valid)
    }

    // MARK: - Too Long (upper boundary)

    func testExactly73Bytes_isTooLong() {
        // 73 ASCII chars: 1 byte over the 72-byte limit.
        let pw = String(repeating: "a", count: 73)
        XCTAssertEqual(pw.count, 73, "fixture must be 73 graphemes")
        XCTAssertEqual(pw.utf8.count, 73, "fixture must be exactly 73 UTF-8 bytes")
        XCTAssertEqual(PasswordValidator.validate(pw), .tooLong)
    }

    // MARK: - Byte rule fires (char count alone would say valid)

    func testMultiByteChars_byteRuleFires_notCharRule() {
        // 🎾 is 1 grapheme cluster and 4 UTF-8 bytes.
        // 19 × 🎾 = 19 graphemes (≥ 8, so char rule would say valid)
        //            76 UTF-8 bytes (> 72, so byte rule fires → .tooLong).
        // This proves the byte limit is checked independently of the character count.
        let ball = "🎾"
        let pw = String(repeating: ball, count: 19)
        XCTAssertEqual(ball.count, 1, "🎾 must be 1 grapheme cluster")
        XCTAssertEqual(ball.utf8.count, 4, "🎾 must be 4 UTF-8 bytes")
        XCTAssertEqual(pw.count, 19, "fixture must be 19 graphemes")
        XCTAssertEqual(pw.utf8.count, 76, "fixture must be 76 UTF-8 bytes")
        // Character count is ≥ 8, so only the byte rule can produce .tooLong here.
        XCTAssertGreaterThanOrEqual(pw.count, 8)
        XCTAssertEqual(PasswordValidator.validate(pw), .tooLong)
    }

    // MARK: - Byte rule checked FIRST (ordering proof)

    func testByteRuleCheckedBeforeCharRule_bothViolated_returnsTooLong() {
        // 👨‍👩‍👧‍👦 (ZWJ family) is exactly 1 grapheme cluster and 25 UTF-8 bytes.
        // 3 × 👨‍👩‍👧‍👦 = 3 graphemes (< 8  → char rule would say .tooShort)
        //                75 UTF-8 bytes (> 72 → byte rule would say .tooLong)
        // Since the byte limit is checked FIRST, the result must be .tooLong — not .tooShort.
        // Without byte-first ordering this test would fail.
        let family = "👨‍👩‍👧‍👦"
        let pw = String(repeating: family, count: 3)
        XCTAssertEqual(family.count, 1, "👨‍👩‍👧‍👦 must be 1 grapheme cluster")
        XCTAssertEqual(family.utf8.count, 25, "👨‍👩‍👧‍👦 must be 25 UTF-8 bytes")
        XCTAssertEqual(pw.count, 3, "fixture must be 3 graphemes (violates < 8 char rule)")
        XCTAssertEqual(pw.utf8.count, 75, "fixture must be 75 UTF-8 bytes (violates > 72 byte rule)")
        // Both conditions violated; byte rule wins because it is checked first.
        XCTAssertLessThan(pw.count, 8)
        XCTAssertGreaterThan(pw.utf8.count, 72)
        XCTAssertEqual(PasswordValidator.validate(pw), .tooLong)
    }
}

import XCTest
@testable import TennisCore

final class SmokeTests: XCTestCase {
    func testPackageBuilds() {
        // Verifies TennisCore links and its placeholder symbol is accessible.
        XCTAssertEqual(TennisCore.version, "0.1.0")
    }
}

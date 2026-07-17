/// MockCVPipelineTests — contract tests for MockCVPipeline (Task 3 / AC6–AC8).
///
/// AC6: zero stubbedResults → process(...) returns [] and does NOT throw.
/// AC7: N stubbedResults → returns exactly those N in order.
/// AC8: stubbedError set → process(...) throws that error (identity checked).

import XCTest
@testable import TennisCore

final class MockCVPipelineTests: XCTestCase {

    // MARK: - Helpers

    /// A dummy URL — MockCVPipeline ignores it entirely.
    private let dummyURL = URL(fileURLWithPath: "/tmp/dummy.mov")

    /// A minimal CourtCalibration — MockCVPipeline ignores it entirely.
    /// Uses the synthesized memberwise init (visible via @testable).
    private let dummyCalibration = CourtCalibration(
        matchId: "test-match",
        imagePoints: [],
        courtPoints: [],
        homographyMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
    )

    /// No-op progress closure.
    private let noOpProgress: (Double) -> Void = { _ in }

    // MARK: - AC6: zero stubbedResults → returns [] without throwing

    func testAC6_emptyStudbedResults_returnsEmptyArrayWithoutThrowing() async throws {
        let mock = MockCVPipeline()
        // stubbedResults defaults to [] — no explicit assignment needed.

        let result = try await mock.process(
            videoURL: dummyURL,
            calibration: dummyCalibration,
            progress: noOpProgress
        )

        XCTAssertEqual(result, [], "AC6: empty stubbedResults must return [] and not throw")
    }

    // MARK: - AC7: N stubbedResults → returns exactly those N in order

    func testAC7_stubbedResults_returnsExactlyThoseResultsInOrder() async throws {
        let mock = MockCVPipeline()

        let first = CVShotResult(
            frameIndex: 10,
            zone: "baseline_left",
            normalizedCourtX: 0.2,
            normalizedCourtY: 0.8,
            ballPixelX: 256.0,
            ballPixelY: 576.0
        )
        let second = CVShotResult(
            frameIndex: 42,
            zone: "front_court_right",
            normalizedCourtX: 0.7,
            normalizedCourtY: 0.3,
            ballPixelX: 896.0,
            ballPixelY: 216.0
        )
        mock.stubbedResults = [first, second]

        let result = try await mock.process(
            videoURL: dummyURL,
            calibration: dummyCalibration,
            progress: noOpProgress
        )

        // Equatable array comparison checks both count and order.
        XCTAssertEqual(result, [first, second],
                       "AC7: must return exactly [first, second] in that order")
    }

    // MARK: - AC8: stubbedError set → process(...) throws that error

    func testAC8_stubbedError_throwsThatError() async {
        let mock = MockCVPipeline()
        mock.stubbedError = CVPipelineError.processingFailed("boom")

        do {
            _ = try await mock.process(
                videoURL: dummyURL,
                calibration: dummyCalibration,
                progress: noOpProgress
            )
            XCTFail("AC8: expected CVPipelineError.processingFailed to be thrown, but no error was thrown")
        } catch CVPipelineError.processingFailed(let message) {
            XCTAssertEqual(message, "boom", "AC8: thrown error must carry the exact configured message")
        } catch {
            XCTFail("AC8: wrong error type thrown: \(error)")
        }
    }
}

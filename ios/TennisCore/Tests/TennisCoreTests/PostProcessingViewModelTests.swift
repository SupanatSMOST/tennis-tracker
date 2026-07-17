/// PostProcessingViewModelTests — Task 6, AC16–AC23 (10 tests → 144 total gate).
///
/// Test split:
///   AC16  (1) initial state == .idle
///   AC17  (1) N results → .done(shots) with shots.count == N
///   AC13V (1) VM-level progress — relayed .processing values are non-decreasing in [0,1]
///   AC18  (1) pipeline error → .failed (never .done, never crash)
///   AC19  (1) submit body: N shots, every source == "cv", zones match CVShotResult.zone
///   AC20  (1) every submitted zone is one of the six §3.1 strings
///   AC21  (1) submit transport failure → .failed, shots retained for retry
///   AC22  (1) dismiss() → .idle
///   AC23a (1) missing video file → .failed; pipeline is not run
///   AC23b (1) video present, calibration missing → .failed; pipeline is not run
///
/// Seeding conventions:
///   - Happy-path tests (AC17/AC13V/AC19/AC20/AC21): write a dummy video file and a
///     valid CalibrationStore JSON to temp dirs so the AC23 guards pass.
///   - AC23a: no video written (calibration would pass, but video guard fires first).
///   - AC23b: video written, but no calibration saved (calibration guard fires).
///   - tearDown removes the temp dir.

import XCTest
@testable import TennisCore

// MARK: - CapturingMockCVPipeline

/// A mock that captures every progress value relayed by the VM for the AC13(VM) test.
///
/// Lives here (not Sources/) because it is test-only; it is NOT the shared MockCVPipeline.
private final class CapturingMockCVPipeline: CVProcessing {
    var stubbedResults: [CVShotResult] = []
    /// Closure called on each `progress` tick, *during* the async process call.
    var onProgress: ((Double) -> Void)?

    func process(
        videoURL: URL,
        calibration: CourtCalibration,
        progress: @escaping (Double) -> Void
    ) async throws -> [CVShotResult] {
        for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
            progress(p)
            onProgress?(p)
        }
        return stubbedResults
    }
}

// MARK: - PostProcessingViewModelTests

final class PostProcessingViewModelTests: XCTestCase {

    // MARK: - Constants

    private let matchID = "test-match-vm-001"
    private let token   = "vm-test-token"

    // MARK: - Temp directories

    private var tempVideoDir: URL!
    private var tempCalDir: URL!

    // MARK: - Setup / tearDown

    override func setUp() {
        super.setUp()
        // Create unique temp subdirs so parallel tests cannot interfere.
        let base = FileManager.default.temporaryDirectory
        tempVideoDir = base.appendingPathComponent(
            "ppvm-video-\(UUID().uuidString)", isDirectory: true)
        tempCalDir = base.appendingPathComponent(
            "ppvm-cal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempVideoDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: tempCalDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempVideoDir)
        try? FileManager.default.removeItem(at: tempCalDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a MatchClient backed by `stub` with a seeded token.
    private func makeMatchClient(stub: StubTransport) -> MatchClient {
        let store = InMemoryTokenStore()
        store.set(token)
        return MatchClient(config: APIConfig(), transport: stub, tokenStore: store)
    }

    /// Writes a dummy video file so `LocalVideoStore.exists(for:)` returns true.
    private func seedVideoFile() {
        let videoStore = LocalVideoStore(baseDirectory: tempVideoDir)
        let url = videoStore.videoURL(for: matchID)   // creates videos/ dir
        try? Data("dummy".utf8).write(to: url)
    }

    /// Saves a minimal valid CalibrationStore entry so `CalibrationStore.load(for:)` returns non-nil.
    private func seedCalibration() throws {
        let calibration = CourtCalibration(
            matchId: matchID,
            imagePoints: [
                CGPointCodable(x: 0.1, y: 0.1),
                CGPointCodable(x: 0.9, y: 0.1),
                CGPointCodable(x: 0.1, y: 0.9),
                CGPointCodable(x: 0.9, y: 0.9)
            ],
            courtPoints: [
                CGPointCodable(x: 0.0, y: 0.0),
                CGPointCodable(x: 1.0, y: 0.0),
                CGPointCodable(x: 0.0, y: 1.0),
                CGPointCodable(x: 1.0, y: 1.0)
            ],
            homographyMatrix: [1,0,0, 0,1,0, 0,0,1]
        )
        let calStore = CalibrationStore(baseDirectory: tempCalDir)
        try calStore.save(calibration)
    }

    /// Creates a VM wired to the given pipeline and the temp-dir stores.
    private func makeVM(pipeline: CVProcessing) -> PostProcessingViewModel {
        PostProcessingViewModel(
            pipeline: pipeline,
            videoStore: LocalVideoStore(baseDirectory: tempVideoDir),
            calibrationStore: CalibrationStore(baseDirectory: tempCalDir)
        )
    }

    /// Three CVShotResults covering distinct zones, used across AC17/AC19/AC20/AC21.
    private var threeShots: [CVShotResult] {
        [
            CVShotResult(frameIndex: 1, zone: "front_court_left",
                         normalizedCourtX: 0.2, normalizedCourtY: 0.2,
                         ballPixelX: 256, ballPixelY: 200),
            CVShotResult(frameIndex: 5, zone: "baseline_right",
                         normalizedCourtX: 0.8, normalizedCourtY: 0.8,
                         ballPixelX: 1000, ballPixelY: 550),
            CVShotResult(frameIndex: 9, zone: "out_left",
                         normalizedCourtX: 0.05, normalizedCourtY: 0.5,
                         ballPixelX: 50, ballPixelY: 360)
        ]
    }

    // MARK: - AC16: initial state is .idle

    func testAC16_initialStateIsIdle() {
        let vm = makeVM(pipeline: MockCVPipeline())
        XCTAssertEqual(vm.state, .idle, "AC16: PostProcessingViewModel must start in .idle")
    }

    // MARK: - AC17: N results → .done(shots) with shots.count == N

    func testAC17_startProcessingProducesDoneWithNShots() async throws {
        try seedCalibration()
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        let client = makeMatchClient(stub: stub)

        await vm.startProcessing(matchId: matchID, matchClient: client)

        guard case .done(let shots) = vm.state else {
            XCTFail("AC17: expected .done, got \(vm.state)")
            return
        }
        XCTAssertEqual(shots.count, 3,
                       "AC17: shots.count must equal the number of stubbed results (3)")
    }

    // MARK: - AC13(VM): VM-level progress is non-decreasing in [0,1]

    func testAC13VM_startProcessingRelaysMonotonicProgress() async throws {
        try seedCalibration()
        seedVideoFile()

        let capturingPipeline = CapturingMockCVPipeline()
        capturingPipeline.stubbedResults = []
        let vm = makeVM(pipeline: capturingPipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":0}"#)
        let client = makeMatchClient(stub: stub)

        var capturedProgressValues: [Double] = []
        // Wire the capturing hook to read the VM's state during each progress callback.
        capturingPipeline.onProgress = { [weak vm] _ in
            if let vm, case .processing(let p) = vm.state {
                capturedProgressValues.append(p)
            }
        }

        await vm.startProcessing(matchId: matchID, matchClient: client)

        XCTAssertFalse(capturedProgressValues.isEmpty,
                       "AC13(VM): at least one .processing(progress) state must be observed")
        for value in capturedProgressValues {
            XCTAssertGreaterThanOrEqual(value, 0.0,
                "AC13(VM): progress value \(value) must be >= 0.0")
            XCTAssertLessThanOrEqual(value, 1.0,
                "AC13(VM): progress value \(value) must be <= 1.0")
        }
        for i in 1..<capturedProgressValues.count {
            XCTAssertGreaterThanOrEqual(capturedProgressValues[i], capturedProgressValues[i - 1],
                "AC13(VM): progress must be non-decreasing; got \(capturedProgressValues[i - 1]) then \(capturedProgressValues[i])")
        }
    }

    // MARK: - AC18: pipeline throws → .failed (never .done, never crash)

    func testAC18_pipelineErrorTransitionsToFailed() async throws {
        try seedCalibration()
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedError = URLError(.timedOut)
        let vm = makeVM(pipeline: pipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":0}"#)
        let client = makeMatchClient(stub: stub)

        await vm.startProcessing(matchId: matchID, matchClient: client)

        if case .done = vm.state {
            XCTFail("AC18: state must never be .done when the pipeline throws")
        }
        guard case .failed = vm.state else {
            XCTFail("AC18: expected .failed, got \(vm.state)")
            return
        }
        // Reaching here proves no crash and state is .failed.
    }

    // MARK: - AC19: submit body has N shots, all source == "cv", zones match

    func testAC19_submitEncodesSourceCVAndMatchingZones() async throws {
        try seedCalibration()
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        // Prime the VM to .done state.
        let primeStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        let primeClient = makeMatchClient(stub: primeStub)
        await vm.startProcessing(matchId: matchID, matchClient: primeClient)

        guard case .done = vm.state else {
            XCTFail("AC19: VM must be .done before submit; got \(vm.state)")
            return
        }

        // Now submit and capture the request body.
        let submitStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        let submitClient = makeMatchClient(stub: submitStub)
        await vm.submit(matchId: matchID, matchClient: submitClient)

        let req = try XCTUnwrap(submitStub.capturedRequest,
                                "AC19: submit must send a request")
        let bodyData = try XCTUnwrap(req.httpBody, "AC19: submit must have an httpBody")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "AC19: httpBody must be a valid JSON object")
        let shotsArray = try XCTUnwrap(json["shots"] as? [[String: Any]],
                                       "AC19: body must contain a 'shots' array")

        XCTAssertEqual(shotsArray.count, 3, "AC19: shots array must have 3 elements")

        for (i, (shot, result)) in zip(shotsArray, threeShots).enumerated() {
            XCTAssertEqual(shot["source"] as? String, "cv",
                           "AC19: shots[\(i)].source must be 'cv', not 'manual'")
            XCTAssertEqual(shot["zone"] as? String, result.zone,
                           "AC19: shots[\(i)].zone must match CVShotResult.zone (\(result.zone))")
        }
    }

    // MARK: - AC20: every submitted zone is one of the six §3.1 strings

    func testAC20_submittedZonesAreAllValidSixStrings() async throws {
        try seedCalibration()
        seedVideoFile()

        let validZones: Set<String> = [
            "front_court_left", "front_court_right",
            "baseline_left", "baseline_right",
            "out_left", "out_right"
        ]

        // Use all three shots (each zone is one of the valid six).
        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        let primeStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        await vm.startProcessing(matchId: matchID, matchClient: makeMatchClient(stub: primeStub))

        let submitStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        await vm.submit(matchId: matchID, matchClient: makeMatchClient(stub: submitStub))

        let req = try XCTUnwrap(submitStub.capturedRequest, "AC20: submit must send a request")
        let bodyData = try XCTUnwrap(req.httpBody, "AC20: submit must have an httpBody")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let shotsArray = try XCTUnwrap(json["shots"] as? [[String: Any]])

        for (i, shot) in shotsArray.enumerated() {
            let zone = try XCTUnwrap(shot["zone"] as? String,
                                     "AC20: shots[\(i)] must have a zone string")
            XCTAssertTrue(validZones.contains(zone),
                "AC20: shots[\(i)].zone '\(zone)' is not one of the six valid §3.1 strings")
        }
    }

    // MARK: - AC21: submit transport failure → .failed, shots retained for retry

    func testAC21_submitTransportFailureRetainsShots() async throws {
        try seedCalibration()
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        // 1. Prime to .done.
        let primeStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        await vm.startProcessing(matchId: matchID, matchClient: makeMatchClient(stub: primeStub))
        guard case .done = vm.state else {
            XCTFail("AC21: setup — VM must reach .done")
            return
        }

        // 2. Submit with a throwing stub → should produce .failed.
        let failStub = StubTransport.throwing(URLError(.notConnectedToInternet))
        await vm.submit(matchId: matchID, matchClient: makeMatchClient(stub: failStub))

        guard case .failed = vm.state else {
            XCTFail("AC21: expected .failed after transport error, got \(vm.state)")
            return
        }

        // 3. Retry with a success stub → VM must re-enter .done using retained shots.
        let retryStub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        await vm.submit(matchId: matchID, matchClient: makeMatchClient(stub: retryStub))

        // The retry's submit captured the request — verify shot count from retained data.
        let req = try XCTUnwrap(retryStub.capturedRequest,
                                "AC21: retry submit must send a request")
        let bodyData = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let shotsArray = try XCTUnwrap(json["shots"] as? [[String: Any]])
        XCTAssertEqual(shotsArray.count, 3,
            "AC21: 3 shots must be retained and re-submitted after a failed submit")
    }

    // MARK: - AC22: dismiss() → .idle

    func testAC22_dismissResetsStateToIdle() async throws {
        try seedCalibration()
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":3}"#)
        await vm.startProcessing(matchId: matchID, matchClient: makeMatchClient(stub: stub))
        guard case .done = vm.state else {
            XCTFail("AC22: setup — VM must reach .done before dismiss")
            return
        }

        vm.dismiss()

        XCTAssertEqual(vm.state, .idle, "AC22: dismiss() must transition state to .idle")
    }

    // MARK: - AC23a: missing video file → .failed; pipeline is NOT run

    func testAC23a_missingVideoProducesFailedWithoutRunningPipeline() async throws {
        // Do NOT seed a video file — `LocalVideoStore.exists(for:)` returns false.
        // Calibration is also absent; since video guard fires first it does not matter.

        // Use N non-empty stubbed results — if the pipeline ran, state would be .done(N).
        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":0}"#)
        await vm.startProcessing(matchId: matchID, matchClient: makeMatchClient(stub: stub))

        guard case .failed = vm.state else {
            XCTFail("AC23a: expected .failed when video is absent, got \(vm.state)")
            return
        }
        // If the pipeline had been run, state would be .done(3), not .failed.
        if case .done = vm.state {
            XCTFail("AC23a: pipeline must NOT be run when video is absent")
        }
    }

    // MARK: - AC23b: video present, calibration missing → .failed; pipeline is NOT run

    func testAC23b_missingCalibrationProducesFailedWithoutRunningPipeline() async throws {
        // Seed video so the first guard passes; do NOT save calibration.
        seedVideoFile()

        let pipeline = MockCVPipeline()
        pipeline.stubbedResults = threeShots
        let vm = makeVM(pipeline: pipeline)

        let stub = StubTransport.make(status: 201, body: #"{"count":0}"#)
        await vm.startProcessing(matchId: matchID, matchClient: makeMatchClient(stub: stub))

        guard case .failed = vm.state else {
            XCTFail("AC23b: expected .failed when calibration is absent, got \(vm.state)")
            return
        }
        // If the pipeline had been run, state would be .done(3), not .failed.
        if case .done = vm.state {
            XCTFail("AC23b: pipeline must NOT be run when calibration is absent")
        }
    }
}

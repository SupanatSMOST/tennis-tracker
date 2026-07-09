/// StubTransport — hermetic HTTPTransport stub for unit tests (AC11).
///
/// Dual capability (load-bearing for AC16 in Task 6):
///   - `.response` mode: returns a canned (Data, HTTPURLResponse)
///   - `.error` mode: throws the supplied Error
///
/// Also captures the most-recently-sent URLRequest so tests can assert
/// headers (AC10) and URL components (AC19) without touching the network.
///
/// AC11 note: because StubTransport never calls URLSession or opens a socket,
/// all tests using it remain hermetic even if localhost:8080 is unreachable.

import Foundation
import XCTest
@testable import TennisCore

/// Configuration for a single canned response or error.
enum StubTransportMode {
    case response(Data, HTTPURLResponse)
    case throwError(Error)
}

final class StubTransport: HTTPTransport {
    /// The mode to use for the next (and every) call to `send`.
    var mode: StubTransportMode

    /// The last URLRequest passed to `send(_:)`. Nil before any call.
    private(set) var capturedRequest: URLRequest?

    init(mode: StubTransportMode) {
        self.mode = mode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        switch mode {
        case .response(let data, let response):
            return (data, response)
        case .throwError(let error):
            throw error
        }
    }
}

// MARK: - Factory helpers

extension StubTransport {
    /// Returns a StubTransport wired to return `statusCode` with `body` JSON string.
    static func make(
        status: Int,
        body: String,
        url: URL = URL(string: "http://localhost:8080")!
    ) -> StubTransport {
        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return StubTransport(mode: .response(data, response))
    }

    /// Returns a StubTransport wired to throw the given error.
    static func throwing(_ error: Error) -> StubTransport {
        StubTransport(mode: .throwError(error))
    }
}

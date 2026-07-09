/// HTTPTransport — the single seam between APIClient and the network.
///
/// Tests inject a stub that can either return a canned (Data, HTTPURLResponse)
/// or throw, making the offline/transport-error path (AC16) expressible without
/// any live network. URLSession is instantiated ONLY in URLSessionTransport.

import Foundation

public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport. The only place URLSession is used in TennisCore.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            // Non-HTTP responses are unexpected; wrap as a transport-layer error.
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}

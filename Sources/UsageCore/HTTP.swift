import Foundation

/// Seam for tests: canned responses instead of the network.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    /// Ephemeral: no disk cache, no cookie jar. We make a handful of small requests an hour.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed("non-HTTP response") }
        return (data, http)
    }
}

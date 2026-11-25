import Foundation
import InvestiQData

/// Fixture-backed HTTP client. Routes are matched by URL substring in registration order.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Route {
        let match: String
        var responses: [Result<HTTPResponse, any Error>]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [HTTPRequest] = []
    public var delayNanoseconds: UInt64 = 0

    public init() {}

    /// Registers responses for URLs containing `match`; multiple responses are returned in sequence
    /// (the last one repeats).
    public func on(_ match: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        add(match, .success(HTTPResponse(statusCode: status, headers: headers, body: body)))
    }

    public func on(_ match: String, error: any Error) { add(match, .failure(error)) }

    private func add(_ match: String, _ result: Result<HTTPResponse, any Error>) {
        lock.lock(); defer { lock.unlock() }
        if let index = routes.firstIndex(where: { $0.match == match }) {
            routes[index].responses.append(result)
        } else {
            routes.append(Route(match: match, responses: [result]))
        }
    }

    public var requests: [HTTPRequest] { lock.withLock { recorded } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let result: Result<HTTPResponse, any Error> = lock.withLock {
            recorded.append(request)
            guard let index = routes.firstIndex(where: { request.url.absoluteString.contains($0.match) }) else {
                return .success(HTTPResponse(statusCode: 404, body: Data()))
            }
            let next = routes[index].responses.first!
            if routes[index].responses.count > 1 { routes[index].responses.removeFirst() }
            return next
        }
        return try result.get()
    }
}

/// Sleeper that records requested delays without waiting.
public final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    public init() {}
    public var sleeps: [Double] { lock.withLock { recorded } }
    public func sleep(seconds: Double) async throws { lock.withLock { recorded.append(seconds) } }
}

public enum Fixtures {
    public static func data(_ name: String, bundle: Bundle) throws -> Data {
        let parts = name.split(separator: ".")
        guard let url = bundle.url(forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }
}

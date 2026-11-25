import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InvestiQSecurity

public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    /// Upper bound for the response body; larger responses are rejected (THREAT_MODEL T13).
    public var maximumResponseBytes: Int
    public var timeout: TimeInterval

    public static let defaultMaximumResponseBytes = 10 * 1024 * 1024
    public static let defaultTimeout: TimeInterval = 15

    public init(url: URL, headers: [String: String] = [:], maximumResponseBytes: Int = defaultMaximumResponseBytes,
                timeout: TimeInterval = defaultTimeout) {
        self.url = url
        self.headers = headers
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = timeout
    }

    /// Credential-free description for logs, cache keys and de-duplication.
    public var redactedKey: String {
        Redactor.redact(url) + "|" + Redactor.redact(headers: headers).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum TransportError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case connectionFailed
    case responseTooLarge
    case insecureURL
    case cancelled
}

/// Transport abstraction so providers can be tested with fixtures and never hit the network in tests.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Production client: ephemeral session (no cookies, no URL cache — the app keeps its own encrypted
/// cache), default TLS validation (never overridden), HTTPS only (docs/SECURITY.md §6).
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    static let resourceTimeout: TimeInterval = 60

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpAdditionalHeaders = ["Accept": "application/json, text/csv, application/xml, text/xml;q=0.9"]
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw TransportError.insecureURL }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard data.count <= request.maximumResponseBytes else { throw TransportError.responseTooLarge }
            guard let http = response as? HTTPURLResponse else { throw TransportError.connectionFailed }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw TransportError.offline
            case .timedOut: throw TransportError.timedOut
            case .cancelled: throw TransportError.cancelled
            default: throw TransportError.connectionFailed
            }
        } catch is CancellationError {
            throw TransportError.cancelled
        }
    }
}

/// Used in offline tests and when the system reports no connectivity.
public struct OfflineHTTPClient: HTTPClient {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw TransportError.offline }
}

import Foundation
import InvestiQCore

/// Supplies API keys at request time (keys live only in the Keychain — docs/SECURITY.md §5).
public protocol CredentialSource: Sendable {
    func apiKey(for providerID: String) -> String?
}

public struct StaticCredentials: CredentialSource {
    private let keys: [String: String]
    public init(_ keys: [String: String]) { self.keys = keys }
    public func apiKey(for providerID: String) -> String? { keys[providerID] }
}

/// Observes request outcomes (persisted as provider metadata; drives outage notifications).
public protocol ProviderHealthObserver: Sendable {
    func recordSuccess(providerID: String, at date: Date) async
    func recordFailure(providerID: String, failure: ProviderFailure, at date: Date) async
}

/// Central request pipeline: rate limiting → de-duplication → retries with backoff → HTTP status mapping.
public actor ProviderGateway {
    private let client: any HTTPClient
    private let clock: any TimeProvider
    private let sleeper: any Sleeper
    private let retryPolicy: RetryPolicy
    private var limiters: [String: RateLimiter] = [:]
    private let deduplicator = InFlightDeduplicator()
    private let observer: (any ProviderHealthObserver)?
    /// Source of jitter in [0, 1); injected so tests are deterministic.
    private let jitter: @Sendable () -> Double

    public init(client: any HTTPClient, clock: any TimeProvider, sleeper: any Sleeper = TaskSleeper(),
                retryPolicy: RetryPolicy = RetryPolicy(), observer: (any ProviderHealthObserver)? = nil,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.client = client
        self.clock = clock
        self.sleeper = sleeper
        self.retryPolicy = retryPolicy
        self.observer = observer
        self.jitter = jitter
    }

    private func limiter(for info: ProviderInfo) -> RateLimiter {
        if let existing = limiters[info.id] { return existing }
        let limiter = RateLimiter(limits: info.limits, clock: clock, sleeper: sleeper)
        limiters[info.id] = limiter
        return limiter
    }

    /// Performs a GET and returns the body of a 2xx response.
    public func fetch(_ request: HTTPRequest, provider: ProviderInfo) async throws -> Data {
        var attempt = 1
        while true {
            do {
                try Task.checkCancellation()
                try await limiter(for: provider).acquire()
                let client = self.client
                let response = try await deduplicator.run(key: request.redactedKey) { try await client.send(request) }
                let body = try Self.check(response)
                await observer?.recordSuccess(providerID: provider.id, at: clock.now())
                return body
            } catch is CancellationError {
                throw ProviderFailure.cancelled
            } catch {
                let failure = Self.map(error)
                if attempt < retryPolicy.maximumAttempts, RetryPolicy.isRetryable(failure) {
                    var delay = retryPolicy.delay(forAttempt: attempt, random: jitter())
                    if case .rateLimited(let retryAfter?) = failure { delay = max(delay, retryAfter) }
                    try? await sleeper.sleep(seconds: delay)
                    attempt += 1
                    continue
                }
                await observer?.recordFailure(providerID: provider.id, failure: failure, at: clock.now())
                throw failure
            }
        }
    }

    static func check(_ response: HTTPResponse) throws -> Data {
        switch response.statusCode {
        case 200..<300: return response.body
        case 401: throw ProviderFailure.unauthorized
        case 402, 403: throw ProviderFailure.notSupported
        case 404: throw ProviderFailure.notFound
        case 429: throw ProviderFailure.rateLimited(retryAfter: response.header("Retry-After").flatMap(Double.init))
        case 500..<600: throw ProviderFailure.serverError(response.statusCode)
        default: throw ProviderFailure.invalidResponse("HTTP \(response.statusCode)")
        }
    }

    static func map(_ error: any Error) -> ProviderFailure {
        if let failure = error as? ProviderFailure { return failure }
        switch error as? TransportError {
        case .offline: return .offline
        case .timedOut: return .timedOut
        case .connectionFailed: return .connectionFailed
        case .responseTooLarge: return .invalidResponse("response too large")
        case .insecureURL: return .misconfigured("insecure URL")
        case .cancelled: return .cancelled
        case nil: return .connectionFailed
        }
    }
}

import Foundation
import InvestiQCore

/// Abstraction over `Task.sleep` so rate limiting and retries are testable without real waiting.
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Request limits of one provider (docs/DATA_PROVIDERS.md §2).
public struct ProviderLimits: Sendable, Hashable {
    public var requestsPerMinute: Int
    public var requestsPerDay: Int?
    /// A request is not queued for longer than this; it fails with `rateLimited` instead.
    public var maximumWaitSeconds: Double

    public init(requestsPerMinute: Int, requestsPerDay: Int? = nil, maximumWaitSeconds: Double = 20) {
        self.requestsPerMinute = requestsPerMinute
        self.requestsPerDay = requestsPerDay
        self.maximumWaitSeconds = maximumWaitSeconds
    }
}

/// Token bucket (per minute) plus a daily counter.
public actor RateLimiter {
    private let limits: ProviderLimits
    private let clock: any TimeProvider
    private let sleeper: any Sleeper
    private var tokens: Double
    private var lastRefill: Date
    private var dailyCount = 0
    private var dailyKey: LocalDate

    public init(limits: ProviderLimits, clock: any TimeProvider, sleeper: any Sleeper) {
        self.limits = limits
        self.clock = clock
        self.sleeper = sleeper
        self.tokens = Double(limits.requestsPerMinute)
        self.lastRefill = clock.now()
        self.dailyKey = LocalDate(clock.now(), timeZone: TimeZone(identifier: "UTC") ?? .current)
    }

    private func refill() {
        let now = clock.now()
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        let rate = Double(limits.requestsPerMinute) / 60
        tokens = min(Double(limits.requestsPerMinute), tokens + elapsed * rate)
        lastRefill = now
        let today = LocalDate(now, timeZone: TimeZone(identifier: "UTC") ?? .current)
        if today != dailyKey { dailyKey = today; dailyCount = 0 }
    }

    /// Waits for a token or throws `ProviderFailure.rateLimited`.
    public func acquire() async throws {
        refill()
        if let daily = limits.requestsPerDay, dailyCount >= daily { throw ProviderFailure.quotaExhausted }
        if tokens < 1 {
            let wait = (1 - tokens) / (Double(limits.requestsPerMinute) / 60)
            guard wait <= limits.maximumWaitSeconds else { throw ProviderFailure.rateLimited(retryAfter: wait) }
            try await sleeper.sleep(seconds: wait)
            refill()
            tokens = max(tokens, 1)
        }
        tokens -= 1
        dailyCount += 1
    }

    public var usedToday: Int { dailyCount }
}

/// Exponential backoff with full jitter for idempotent GET requests (docs/DATA_PROVIDERS.md §1).
public struct RetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var baseDelay: Double
    public var maximumDelay: Double

    public init(maximumAttempts: Int = 3, baseDelay: Double = 0.5, maximumDelay: Double = 8) {
        self.maximumAttempts = maximumAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    /// Delay before retry number `attempt` (1-based), using a [0,1) random factor.
    public func delay(forAttempt attempt: Int, random: Double) -> Double {
        let exponential = min(maximumDelay, baseDelay * pow(2, Double(attempt - 1)))
        return exponential * random
    }

    public static func isRetryable(_ failure: ProviderFailure) -> Bool {
        switch failure {
        case .timedOut, .connectionFailed, .serverError: return true
        case .rateLimited(let retryAfter): return (retryAfter ?? 0) <= 10
        default: return false
        }
    }
}

/// Shares one in-flight request between identical callers.
actor InFlightDeduplicator {
    private var tasks: [String: Task<HTTPResponse, any Error>] = [:]

    func run(key: String, operation: @escaping @Sendable () async throws -> HTTPResponse) async throws -> HTTPResponse {
        if let existing = tasks[key] { return try await existing.value }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

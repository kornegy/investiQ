import Foundation
import InvestiQCore

/// Exponential lockout after repeated failed unlock attempts (docs/SECURITY.md §4).
public struct LoginThrottlePolicy: Sendable, Equatable {
    /// Failures allowed before the first lockout.
    public var freeAttempts: Int
    public var baseLockout: TimeInterval
    public var maximumLockout: TimeInterval

    public init(freeAttempts: Int = 5, baseLockout: TimeInterval = 30, maximumLockout: TimeInterval = 15 * 60) {
        self.freeAttempts = freeAttempts
        self.baseLockout = baseLockout
        self.maximumLockout = maximumLockout
    }

    /// Lockout after `failures` consecutive failures: none before `freeAttempts`, then
    /// 30 s, 60 s, 120 s … capped at 15 min.
    public func lockoutDuration(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= freeAttempts else { return nil }
        let exponent = min(failures - freeAttempts, 30)
        return min(baseLockout * pow(2, Double(exponent)), maximumLockout)
    }
}

public struct LoginThrottleState: Codable, Equatable, Sendable {
    public var failedAttempts: Int
    public var lastFailureAt: Date?
    public init(failedAttempts: Int = 0, lastFailureAt: Date? = nil) {
        self.failedAttempts = failedAttempts
        self.lastFailureAt = lastFailureAt
    }
}

public enum LoginThrottleDecision: Equatable, Sendable {
    case allowed(remainingFreeAttempts: Int)
    case locked(until: Date)
}

/// Persists throttle state in the `SecureStore` so it survives restarts.
public struct LoginThrottle: Sendable {
    private let store: any SecureStore
    private let account: String
    private let policy: LoginThrottlePolicy
    private let clock: any TimeProvider

    public init(store: any SecureStore, account: String, policy: LoginThrottlePolicy = .init(), clock: any TimeProvider) {
        self.store = store
        self.account = account
        self.policy = policy
        self.clock = clock
    }

    public func state() throws -> LoginThrottleState {
        guard let data = try store.data(service: .authThrottle, account: account) else { return LoginThrottleState() }
        // Corrupted state is treated as the maximum lockout rather than silently reset (fail closed).
        guard let decoded = try? JSONDecoder().decode(LoginThrottleState.self, from: data) else {
            return LoginThrottleState(failedAttempts: policy.freeAttempts + 30, lastFailureAt: clock.now())
        }
        return decoded
    }

    public func decision() throws -> LoginThrottleDecision {
        let current = try state()
        guard let duration = policy.lockoutDuration(afterFailures: current.failedAttempts),
              let last = current.lastFailureAt else {
            return .allowed(remainingFreeAttempts: max(policy.freeAttempts - current.failedAttempts, 0))
        }
        let now = clock.now()
        // Clock rolled back: never shorten a lockout (treat as freshly locked).
        if now < last { return .locked(until: now.addingTimeInterval(duration)) }
        let until = last.addingTimeInterval(duration)
        return now < until ? .locked(until: until) : .allowed(remainingFreeAttempts: 0)
    }

    @discardableResult
    public func recordFailure() throws -> LoginThrottleDecision {
        var current = try state()
        current.failedAttempts += 1
        current.lastFailureAt = clock.now()
        try store.set(try JSONEncoder().encode(current), service: .authThrottle, account: account)
        return try decision()
    }

    public func recordSuccess() throws {
        try store.remove(service: .authThrottle, account: account)
    }
}

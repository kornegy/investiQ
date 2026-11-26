import Foundation
import InvestiQPersistence

/// Clears the encrypted market-data cache (quotes, histories, news, HTTP cache). User data is untouched.
public struct CacheMaintenance: Sendable {
    private let store: DatabaseStore
    public init(store: DatabaseStore) { self.store = store }

    public func clearAll() async throws {
        try await store.write { try CacheRecords.clearAll(in: $0) }
    }
}

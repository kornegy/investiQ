import Foundation
import InvestiQCore
import InvestiQPersistence

/// Stores the planner budget and goals in the encrypted user database.
public actor PlannerService {
    private let store: DatabaseStore
    private let clock: any TimeProvider

    public init(store: DatabaseStore, clock: any TimeProvider) {
        self.store = store
        self.clock = clock
    }

    public func budget() async throws -> BudgetInput? {
        try await store.read { try PlannerRecords.budget(in: $0) }
    }

    public func save(_ budget: BudgetInput) async throws {
        let now = clock.now()
        try await store.write { try PlannerRecords.save(budget, now: now, in: $0) }
    }

    public func goals() async throws -> [PlannerGoal] {
        try await store.read { try PlannerRecords.goals(in: $0) }
    }

    public func save(_ goal: PlannerGoal) async throws {
        try await store.write { try PlannerRecords.upsert(goal, in: $0) }
    }

    public func deleteGoal(_ id: UUID) async throws {
        try await store.write { try PlannerRecords.deleteGoal(id, in: $0) }
    }
}

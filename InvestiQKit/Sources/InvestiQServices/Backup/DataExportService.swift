import Foundation
import InvestiQCore
import InvestiQPersistence

/// Machine-readable export of everything the user entered (GDPR-style data portability). It is NOT
/// encrypted — the UI says so — and contains no API keys, passwords or cached market data.
public struct DataExportService: Sendable {
    public static let formatVersion = 1

    struct Export: Encodable {
        var formatVersion: Int
        var exportedAt: Date
        var schemaVersion: Int
        var profile: UserProfile?
        var financialProfile: FinancialProfile?
        var instruments: [Instrument]
        var portfolios: [PortfolioExport]
        var budget: BudgetInput?
        var goals: [PlannerGoal]
        var learningProgress: [LessonProgress]
        var forecasts: [ForecastRow]
        var notificationRules: [NotificationRule]
    }

    struct PortfolioExport: Encodable {
        var portfolio: Portfolio
        var transactions: [Transaction]
        var simulator: SimulatorSessionExport?
    }

    struct SimulatorSessionExport: Encodable {
        var mode: String
        var startDate: LocalDate
        var simulatedDate: LocalDate
        var startingCapital: Decimal
        var feeModel: FeeModel
    }

    private let store: DatabaseStore
    private let clock: any TimeProvider

    public init(store: DatabaseStore, clock: any TimeProvider) {
        self.store = store
        self.clock = clock
    }

    public func exportJSON() async throws -> Data {
        let now = clock.now()
        let export = try await store.read { db -> Export in
            let sessions = Dictionary(uniqueKeysWithValues: try SimulatorRecords.all(in: db).map { ($0.portfolioID, $0) })
            let portfolios = try PortfolioRecords.all(in: db).map { portfolio in
                PortfolioExport(portfolio: portfolio, transactions: try TransactionRecords.all(portfolio: portfolio.id, in: db),
                                simulator: sessions[portfolio.id].map {
                                    SimulatorSessionExport(mode: $0.mode.rawValue, startDate: $0.startDate, simulatedDate: $0.simDate,
                                                           startingCapital: $0.startingCapital, feeModel: $0.feeModel)
                                })
            }
            return Export(formatVersion: Self.formatVersion, exportedAt: now, schemaVersion: db.userVersion,
                          profile: try ProfileRecords.load(from: db), financialProfile: try FinancialProfileRecords.load(from: db),
                          instruments: try InstrumentRecords.allInstruments(in: db), portfolios: portfolios,
                          budget: try PlannerRecords.budget(in: db), goals: try PlannerRecords.goals(in: db),
                          learningProgress: try LearningRecords.all(in: db), forecasts: try ForecastRecords.all(in: db),
                          notificationRules: try NotificationRecords.rules(in: db))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }
}

import Foundation
import Observation
import InvestiQCore
import InvestiQServices

public struct ForecastRecordItem: Sendable, Identifiable, Hashable {
    public var row: ForecastRow
    public var instrumentName: String
    public var id: ForecastID { row.id }
}

/// Public accuracy record (spec §14): every stored forecast with its outcome, failures included,
/// and per-model accuracy compared with the naive baseline.
@MainActor
@Observable
public final class ForecastAccuracyViewModel {
    public private(set) var items: [ForecastRecordItem] = []
    public private(set) var accuracy: [ModelAccuracy] = []
    public private(set) var isLoading = false
    public private(set) var error: Message?
    public private(set) var lastEvaluatedCount: Int?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public func load(evaluate: Bool = true) async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if evaluate { lastEvaluatedCount = try await services.forecasts.evaluateDueForecasts() }
            let rows = try await services.forecasts.forecasts()
            var names: [InstrumentID: String] = [:]
            for id in Set(rows.map(\.instrumentID)) {
                names[id] = try await services.instruments.entry(id)?.instrument.name
            }
            items = rows.map { ForecastRecordItem(row: $0, instrumentName: names[$0.instrumentID] ?? $0.listingKey) }
            accuracy = try await services.forecasts.accuracy()
            error = nil
        } catch {
            self.error = Message("forecast.error.loadFailed")
        }
    }

    public var pendingCount: Int { items.filter { $0.row.evaluation == nil }.count }
    public var evaluatedCount: Int { items.count - pendingCount }
}

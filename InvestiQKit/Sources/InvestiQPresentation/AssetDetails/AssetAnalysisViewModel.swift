import Foundation
import Observation
import InvestiQCore
import InvestiQAnalytics
import InvestiQServices

/// Horizons for historical scenario ranges (trading days).
public enum ScenarioHorizon: Int, CaseIterable, Sendable, Identifiable {
    case oneYear = 252
    case threeYears = 756
    public var id: Int { rawValue }
    public var labelKey: String { self == .oneYear ? "scenario.horizon.oneYear" : "scenario.horizon.threeYears" }
}

public enum ForecastHorizon: Int, CaseIterable, Sendable, Identifiable {
    case oneMonth = 21
    case threeMonths = 63
    public var id: Int { rawValue }
    public var labelKey: String { self == .oneMonth ? "forecast.horizon.oneMonth" : "forecast.horizon.threeMonths" }
}

/// Analysis layer of the asset page (spec §10–14): neutral statuses and thesis worksheet, bond and ETF
/// analytics, historical scenario ranges, walk-forward validation and the forecast ledger.
/// Inputs come from the already loaded `AssetDetailsViewModel` — nothing is fetched twice.
@MainActor
@Observable
public final class AssetAnalysisViewModel {
    public private(set) var assessment: InstrumentAssessment?
    public private(set) var bondAnalysis: InstrumentAnalyzer.BondAnalysis?
    public private(set) var etfAnalysis: InstrumentAnalyzer.ETFAnalysis?
    public private(set) var scenarios: [ScenarioRange]?
    public private(set) var scenarioObservationsRequired = ScenarioBuilder.requiredObservations(horizon: ScenarioHorizon.oneYear.rawValue)
    public private(set) var observations = 0
    public var scenarioHorizon: ScenarioHorizon = .oneYear { didSet { recomputeScenarios() } }
    /// Illustrative amount for scenarios and the sensitivity grid (user-chosen, never a recommendation).
    public var illustrationAmount: Decimal = 10_000 { didSet { recomputeScenarios() } }
    public private(set) var validations: [ValidationMetrics] = []
    public private(set) var isValidating = false
    public private(set) var validationAttempted = false
    public private(set) var recordedForecast: ForecastRow?
    public private(set) var forecastMessage: Message?
    public var forecastModel: ForecastModelID = .naive
    public var forecastHorizon: ForecastHorizon = .oneMonth

    private let app: AppModel
    private var closes: [Double] = []
    private var series: PriceSeries?
    private var listing: Listing?
    private var instrumentID: InstrumentID?
    private var historyIsStale = false

    public init(app: AppModel) { self.app = app }

    public func update(from details: AssetDetailsViewModel) {
        guard let entry = details.entry else { return }
        instrumentID = entry.instrument.id
        listing = entry.listing
        let history = details.history?.value
        series = history?.value
        closes = history?.value.bars.map { $0.close.doubleValue } ?? []
        observations = closes.count
        historyIsStale = details.history?.isStale ?? false
        let isConflicting = !(details.quote?.value?.metadata.conflicts.isEmpty ?? true)
            || !(details.fundamentals?.value?.metadata.conflicts.isEmpty ?? true)
        let isStale = historyIsStale || (details.quote?.isStale ?? false)
        switch entry.instrument.kind {
        case .stock:
            assessment = InstrumentAnalyzer.assessStock(fundamentals: details.fundamentals?.value?.value, series: series,
                                                         isStale: isStale, isConflicting: isConflicting)
        case .etf:
            etfAnalysis = details.etf.map { InstrumentAnalyzer.analyzeETF($0, baseCurrency: app.preferences.baseCurrency) }
            assessment = nil
        case .governmentBond, .corporateBond:
            assessment = nil
            if let terms = details.bond, let quote = details.quote?.value?.value.price {
                // Bond quotes are already clean prices in percent of face value (market convention).
                bondAnalysis = InstrumentAnalyzer.analyzeBond(terms, cleanPrice: quote.doubleValue, settlement: app.environment.clock.today())
            } else {
                bondAnalysis = nil
            }
        }
        recomputeScenarios()
    }

    private func recomputeScenarios() {
        let horizon = scenarioHorizon.rawValue
        scenarioObservationsRequired = ScenarioBuilder.requiredObservations(horizon: horizon)
        scenarios = ScenarioBuilder.scenarios(history: closes, horizon: horizon, startValue: illustrationAmount.doubleValue)
    }

    /// Sensitivity grid around the historical median annual return (illustration of assumptions only).
    public var sensitivity: [ScenarioBuilder.SensitivityCell] {
        guard let base = scenarios?.first(where: { $0.kind == .base }) else { return [] }
        let years = Double(scenarioHorizon.rawValue) / 252
        let annual = pow(1 + base.periodReturn, 1 / years) - 1
        return ScenarioBuilder.sensitivity(amount: illustrationAmount.doubleValue, baseAnnualReturn: annual)
    }

    /// Walk-forward validation of every model on this instrument's history (runs off the main actor).
    public func runValidation() async {
        guard let series, !isValidating else { return }
        isValidating = true
        defer { isValidating = false; validationAttempted = true }
        let horizon = forecastHorizon.rawValue
        validations = await Task.detached(priority: .userInitiated) {
            let validator = WalkForwardValidator(horizon: horizon, step: horizon)
            return ForecastModelID.allCases.compactMap { validator.validate($0, series: series) }
        }.value
    }

    /// Records a forecast in the append-only ledger so it can be evaluated later.
    public func recordForecast(allowStaleInput: Bool = false) async {
        guard let services = app.services, let listing, let instrumentID else { return }
        do {
            recordedForecast = try await services.forecasts.createForecast(instrumentID: instrumentID, listing: listing, model: forecastModel,
                                                                            horizon: forecastHorizon.rawValue, allowStaleInput: allowStaleInput)
            forecastMessage = nil
        } catch ForecastServiceError.model(.staleInput(let last)) {
            forecastMessage = Message("forecast.error.staleInput", [.date(last)])
        } catch ForecastServiceError.model(.insufficientHistory(let available, let required)) {
            forecastMessage = Message("forecast.error.insufficientHistory", [.integer(available), .integer(required)])
        } catch ForecastServiceError.noHistory {
            forecastMessage = Message("forecast.error.noHistory")
        } catch {
            forecastMessage = Message("forecast.error.saveFailed")
        }
    }

    public var isHistoryStale: Bool { historyIsStale }
}

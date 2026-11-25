import Foundation
import InvestiQCore
import InvestiQData
import InvestiQContent

public struct CalendarOutcome: Sendable {
    public var events: [EconomicEvent]
    public var bundledVerifiedOn: LocalDate?
    public var failures: [ProviderAttempt]
}

/// Economic calendar (spec §16): verified bundled central-bank and statistics dates plus earnings dates of
/// instruments in the user's library from providers. Times keep their source time zone.
public actor CalendarService {
    public static let horizonDays = 120

    private let registry: ProviderRegistry
    private let instruments: InstrumentService
    private let clock: any TimeProvider

    public init(registry: ProviderRegistry, instruments: InstrumentService, clock: any TimeProvider) {
        self.registry = registry
        self.instruments = instruments
        self.clock = clock
    }

    public func upcoming(days: Int = horizonDays) async throws -> CalendarOutcome {
        let today = clock.today()
        let range = DateRange(start: today, end: today.adding(days: days))
        let bundled = try EventCatalog.load()
        var events = bundled.events.filter { $0.date >= range.start && $0.date <= range.end }
        var failures: [ProviderAttempt] = []
        let library = try await instruments.library()
        let bySymbol = Dictionary(library.compactMap { entry in entry.listing.map { ($0.ticker.rawValue.uppercased(), entry) } },
                                  uniquingKeysWith: { first, _ in first })
        for provider in registry.earnings {
            do {
                for earning in try await provider.earnings(range: range) {
                    guard let entry = bySymbol[earning.symbol.uppercased()] else { continue }
                    events.append(EconomicEvent(id: "earnings-\(earning.symbol)-\(earning.date.iso)", kind: .earningsReport,
                                                institution: entry.instrument.name, region: entry.instrument.country ?? "",
                                                date: earning.date, time: nil, timeZone: "UTC", status: .scheduled,
                                                noteKey: earning.hour.map { "calendar.earnings.\($0)" }, instrumentID: entry.id,
                                                symbol: earning.symbol))
                }
                break
            } catch {
                failures.append(ProviderAttempt(providerID: provider.info.id, failure: error as? ProviderFailure ?? .connectionFailed))
            }
        }
        let unique = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        return CalendarOutcome(events: unique.sorted { ($0.date, $0.id) < ($1.date, $1.id) }, bundledVerifiedOn: bundled.verifiedOn,
                               failures: failures)
    }
}

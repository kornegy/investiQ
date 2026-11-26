import Foundation
import Observation
import InvestiQCore
import InvestiQServices

@MainActor
@Observable
public final class CalendarViewModel {
    public private(set) var events: [EconomicEvent] = []
    public private(set) var verifiedOn: LocalDate?
    public private(set) var isLoading = false
    public private(set) var error: Message?
    public var kindFilter: EconomicEventKind?
    public var regionFilter: String?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public func load() async {
        guard let services = app.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let outcome = try await services.calendar.upcoming()
            events = outcome.events
            verifiedOn = outcome.bundledVerifiedOn
            error = outcome.failures.isEmpty ? nil : Message("calendar.error.earningsUnavailable")
        } catch {
            self.error = Message("calendar.error.loadFailed")
        }
    }

    public var regions: [String] { Array(Set(events.map(\.region).filter { !$0.isEmpty })).sorted() }

    public var filtered: [EconomicEvent] {
        events.filter { event in
            (kindFilter.map { event.kind == $0 } ?? true) && (regionFilter.map { event.region == $0 } ?? true)
        }
    }

    /// Events grouped by date (ascending).
    public var days: [(date: LocalDate, events: [EconomicEvent])] {
        Dictionary(grouping: filtered, by: \.date).map { ($0.key, $0.value) }.sorted { $0.date < $1.date }
    }

    /// Title key: `calendar.title.<kind>` with the institution as argument.
    public func title(_ event: EconomicEvent) -> Message {
        Message("calendar.title.\(event.kind.rawValue)", [.text(event.institution)])
    }
}

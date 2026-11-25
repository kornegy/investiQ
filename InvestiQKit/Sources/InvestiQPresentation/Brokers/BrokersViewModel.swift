import Foundation
import Observation
import InvestiQCore
import InvestiQContent

/// Informational broker directory (spec §19). In educational mode (minors) no broker websites are offered
/// — only the supervisors' registers — so there is no path to opening or funding an account.
@MainActor
@Observable
public final class BrokersViewModel {
    public private(set) var brokers: [BrokerEntry] = []
    public private(set) var verifiedOn: LocalDate?
    public private(set) var error: Message?
    public var presenceFilter: BrokerEntry.CzechPresence?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public func load() {
        do {
            let catalog = try BrokerCatalog.load()
            brokers = catalog.brokers
            verifiedOn = catalog.verifiedOn
            error = nil
        } catch {
            self.error = Message("brokers.error.loadFailed")
        }
    }

    public var filtered: [BrokerEntry] { brokers.filter { presenceFilter == nil || $0.czechPresence == presenceFilter } }
    public var isEducationalMode: Bool { app.educationalMode }

    /// Broker websites are hidden for minors (no sign-up or funding paths); registers stay available.
    public func websiteURL(_ broker: BrokerEntry) -> URL? { isEducationalMode ? nil : broker.websiteURL }
}

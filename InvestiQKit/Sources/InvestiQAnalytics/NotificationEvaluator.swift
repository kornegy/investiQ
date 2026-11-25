import Foundation
import InvestiQCore

/// Turns current facts into informative notifications (spec §23). Pure and deterministic; wording is
/// factual ("scheduled", "changed by"), never urging action. Deduplication keys include the date or value
/// that makes the fact unique.
public enum NotificationEvaluator {
    public struct PriceChange: Sendable {
        public var instrumentID: InstrumentID
        public var name: String
        public var changeFraction: Double
        public var date: LocalDate
        public init(instrumentID: InstrumentID, name: String, changeFraction: Double, date: LocalDate) {
            self.instrumentID = instrumentID; self.name = name; self.changeFraction = changeFraction; self.date = date
        }
    }

    public struct DatedItem: Sendable {
        public var key: String
        public var name: String
        public var date: LocalDate
        public init(key: String, name: String, date: LocalDate) { self.key = key; self.name = name; self.date = date }
    }

    public struct RiskLevelChange: Sendable {
        public var portfolioName: String
        public var categoryKey: String
        public var from: String
        public var to: String
        public var computedAt: Date
        public init(portfolioName: String, categoryKey: String, from: String, to: String, computedAt: Date) {
            self.portfolioName = portfolioName; self.categoryKey = categoryKey; self.from = from; self.to = to; self.computedAt = computedAt
        }
    }

    public struct Inputs: Sendable {
        public var today: LocalDate
        public var priceChanges: [PriceChange] = []
        public var earnings: [DatedItem] = []
        public var economicEvents: [(item: DatedItem, title: Message)] = []
        public var dividends: [DatedItem] = []
        public var coupons: [DatedItem] = []
        public var maturities: [DatedItem] = []
        public var riskChanges: [RiskLevelChange] = []
        public var staleInstruments: [String] = []
        public var failingProviders: [String] = []
        public init(today: LocalDate) { self.today = today }
    }

    public static func evaluate(_ inputs: Inputs, rules: [NotificationRule]) -> [NotificationCandidate] {
        let active = Dictionary(rules.filter(\.enabled).map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let today = inputs.today
        var result: [NotificationCandidate] = []

        func within(_ date: LocalDate, _ rule: NotificationRule?) -> Bool {
            guard let rule else { return false }
            let days = (rule.threshold ?? 0) as NSDecimalNumber
            return date >= today && date <= today.adding(days: days.intValue)
        }

        if let rule = active[.priceMove], let threshold = rule.threshold?.doubleValue {
            for change in inputs.priceChanges where abs(change.changeFraction) >= threshold {
                result.append(NotificationCandidate(
                    dedupKey: "price:\(change.instrumentID.string):\(change.date.iso)", kind: .priceMove,
                    title: Message("notification.priceMove.title", [.text(change.name)]),
                    body: Message("notification.priceMove.body", [.percent(change.changeFraction, fractionDigits: 1),
                                                                  .percent(threshold, fractionDigits: 0)])))
            }
        }
        for item in inputs.earnings where within(item.date, active[.earningsReport]) {
            result.append(NotificationCandidate(dedupKey: "earnings:\(item.key):\(item.date.iso)", kind: .earningsReport,
                                                title: Message("notification.earnings.title", [.text(item.name)]),
                                                body: Message("notification.earnings.body", [.date(item.date)])))
        }
        for event in inputs.economicEvents where within(event.item.date, active[.economicEvent]) {
            result.append(NotificationCandidate(dedupKey: "event:\(event.item.key)", kind: .economicEvent, title: event.title,
                                                body: Message("notification.event.body", [.date(event.item.date)])))
        }
        for item in inputs.dividends where within(item.date, active[.dividendPayment]) {
            result.append(NotificationCandidate(dedupKey: "dividend:\(item.key):\(item.date.iso)", kind: .dividendPayment,
                                                title: Message("notification.dividend.title", [.text(item.name)]),
                                                body: Message("notification.dividend.body", [.date(item.date)])))
        }
        for item in inputs.coupons where within(item.date, active[.couponPayment]) {
            result.append(NotificationCandidate(dedupKey: "coupon:\(item.key):\(item.date.iso)", kind: .couponPayment,
                                                title: Message("notification.coupon.title", [.text(item.name)]),
                                                body: Message("notification.coupon.body", [.date(item.date)])))
        }
        for item in inputs.maturities where within(item.date, active[.bondMaturity]) {
            result.append(NotificationCandidate(dedupKey: "maturity:\(item.key):\(item.date.iso)", kind: .bondMaturity,
                                                title: Message("notification.maturity.title", [.text(item.name)]),
                                                body: Message("notification.maturity.body", [.date(item.date)])))
        }
        if active[.riskChange] != nil {
            for change in inputs.riskChanges {
                result.append(NotificationCandidate(
                    dedupKey: "risk:\(change.portfolioName):\(change.categoryKey):\(InstantCoding.string(from: change.computedAt))", kind: .riskChange,
                    title: Message("notification.risk.title", [.text(change.portfolioName)]),
                    body: Message("notification.risk.body", [.key("risk.category.\(change.categoryKey)"), .key("risk.level.\(change.from)"),
                                                             .key("risk.level.\(change.to)")])))
            }
        }
        if active[.staleData] != nil, !inputs.staleInstruments.isEmpty {
            result.append(NotificationCandidate(dedupKey: "stale:\(today.iso)", kind: .staleData, title: Message("notification.stale.title"),
                                                body: Message("notification.stale.body", [.integer(inputs.staleInstruments.count)])))
        }
        if active[.providerOutage] != nil {
            for provider in inputs.failingProviders {
                result.append(NotificationCandidate(dedupKey: "outage:\(provider):\(today.iso)", kind: .providerOutage,
                                                    title: Message("notification.outage.title"),
                                                    body: Message("notification.outage.body", [.text(provider)])))
            }
        }
        return result
    }
}

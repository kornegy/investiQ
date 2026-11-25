import Foundation

/// Notification types of spec §23 (stored in `notification_rules.kind`).
public enum NotificationKind: String, Codable, Sendable, CaseIterable, Hashable {
    case priceMove, earningsReport, economicEvent, dividendPayment, couponPayment, bondMaturity, riskChange, staleData, providerOutage
}

/// A global (instrument- and portfolio-independent) rule per kind; `threshold` is used by `priceMove`
/// (fraction, e.g. 0.05) and as lead time in days by the scheduled kinds.
public struct NotificationRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: NotificationKind
    public var threshold: Decimal?
    public var enabled: Bool
    public var createdAt: Date
    public var lastTriggeredAt: Date?

    public init(id: UUID = UUID(), kind: NotificationKind, threshold: Decimal?, enabled: Bool, createdAt: Date, lastTriggeredAt: Date? = nil) {
        self.id = id; self.kind = kind; self.threshold = threshold; self.enabled = enabled; self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
    }

    /// Defaults: everything on; price moves of 5 % or more; scheduled events announced 2 days ahead;
    /// bond maturities 30 days ahead.
    public static func defaults(now: Date) -> [NotificationRule] {
        NotificationKind.allCases.map { kind in
            let threshold: Decimal?
            switch kind {
            case .priceMove: threshold = Decimal(string: "0.05")
            case .earningsReport, .economicEvent, .dividendPayment, .couponPayment: threshold = 2
            case .bondMaturity: threshold = 30
            case .riskChange, .staleData, .providerOutage: threshold = nil
            }
            return NotificationRule(kind: kind, threshold: threshold, enabled: true, createdAt: now)
        }
    }
}

/// An informative notification ready for delivery. Texts are message descriptors localised by the app.
public struct NotificationCandidate: Sendable, Hashable, Identifiable {
    /// Stable key: the same fact never produces a second notification.
    public var dedupKey: String
    public var kind: NotificationKind
    public var title: Message
    public var body: Message
    public var id: String { dedupKey }

    public init(dedupKey: String, kind: NotificationKind, title: Message, body: Message) {
        self.dedupKey = dedupKey; self.kind = kind; self.title = title; self.body = body
    }
}

import Foundation
import Observation
import InvestiQCore
import InvestiQServices

@MainActor
@Observable
public final class NotificationSettingsViewModel {
    public private(set) var rules: [NotificationRule] = []
    public private(set) var authorized = false
    public private(set) var lastCheckCount: Int?
    public private(set) var error: Message?

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public func load() async {
        guard let services = app.services else { return }
        authorized = await app.environment.notificationDelivery.isAuthorized()
        do {
            rules = try await services.notifications.rules()
            error = nil
        } catch {
            self.error = Message("notifications.error.loadFailed")
        }
    }

    public func requestAuthorization() async {
        authorized = await app.environment.notificationDelivery.requestAuthorization()
    }

    public func setEnabled(_ kind: NotificationKind, _ enabled: Bool) async {
        await update(kind) { $0.enabled = enabled }
    }

    /// Price-move threshold in percent (1–50).
    public func setPriceThreshold(percent: Int) async {
        let clamped = min(50, max(1, percent))
        await update(.priceMove) { $0.threshold = Decimal(clamped) / 100 }
    }

    /// Lead time in days for scheduled kinds (earnings, economic events, dividends, coupons, maturities).
    public func setLeadDays(_ kind: NotificationKind, days: Int) async {
        guard Self.scheduledKinds.contains(kind) else { return }
        await update(kind) { $0.threshold = Decimal(min(90, max(0, days))) }
    }

    public static let scheduledKinds: Set<NotificationKind> = [.earningsReport, .economicEvent, .dividendPayment, .couponPayment, .bondMaturity]

    public func leadDays(_ kind: NotificationKind) -> Int? {
        guard Self.scheduledKinds.contains(kind), let threshold = rules.first(where: { $0.kind == kind })?.threshold else { return nil }
        return NSDecimalNumber(decimal: threshold).intValue
    }

    public var priceThresholdPercent: Int {
        let fraction = rules.first { $0.kind == .priceMove }?.threshold ?? Decimal(5) / 100
        return NSDecimalNumber(decimal: fraction * 100).intValue
    }

    /// Kinds whose data is not available from the configured providers in this version.
    public func needsUnavailableData(_ kind: NotificationKind) -> Bool {
        kind == .dividendPayment && !(app.isDemo)
    }

    private func update(_ kind: NotificationKind, _ change: (inout NotificationRule) -> Void) async {
        guard let services = app.services, let index = rules.firstIndex(where: { $0.kind == kind }) else { return }
        var rule = rules[index]
        change(&rule)
        do {
            try await services.notifications.save(rule)
            rules[index] = rule
            error = nil
        } catch {
            self.error = Message("notifications.error.saveFailed")
        }
    }

    public func checkNow() async {
        lastCheckCount = await app.checkNotifications()
    }
}

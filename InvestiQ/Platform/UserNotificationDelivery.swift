import UserNotifications
import InvestiQCore
import InvestiQPresentation

/// Local macOS notifications (spec §23). Texts are localised here; they contain instrument names and
/// percentages but never amounts or holdings, because notifications can appear on the lock screen.
@MainActor
final class UserNotificationDelivery: NotificationDelivering {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            return false
        }
    }

    func deliver(_ notifications: [NotificationCandidate]) async {
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = L10n.string(notification.title)
            content.body = L10n.string(notification.body)
            content.threadIdentifier = notification.kind.rawValue
            let request = UNNotificationRequest(identifier: notification.dedupKey, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                // A rejected request (e.g. permission withdrawn meanwhile) is not retried; the next check
                // evaluates only new facts, so nothing is sent twice.
                continue
            }
        }
    }
}

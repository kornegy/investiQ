import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Settings → Notifications (spec §23). Informative notifications only; checked while InvestiQ is running.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: NotificationSettingsViewModel?

    var body: some View {
        Group {
            if let model { NotificationSettingsContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = NotificationSettingsViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct NotificationSettingsContent: View {
    let model: NotificationSettingsViewModel

    var body: some View {
        Form {
            Section {
                Text("notifications.intro").fixedSize(horizontal: false, vertical: true)
                Label("notifications.runningOnly", systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                if model.authorized {
                    Label("notifications.allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Button("notifications.allow") { Task { await model.requestAuthorization() } }
                    Text("notifications.notAllowed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("notifications.types") {
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Toggle(L10n.key("notifications.kind", rule.kind.rawValue), isOn: Binding(
                            get: { rule.enabled }, set: { value in Task { await model.setEnabled(rule.kind, value) } }))
                        if rule.kind == .priceMove {
                            Stepper(value: Binding(get: { model.priceThresholdPercent },
                                                   set: { value in Task { await model.setPriceThreshold(percent: value) } }), in: 1...50) {
                                Text(L10n.string(Message("notifications.threshold", [.integer(model.priceThresholdPercent)])))
                            }
                            .disabled(!rule.enabled)
                        }
                        if let days = model.leadDays(rule.kind) {
                            Stepper(value: Binding(get: { days }, set: { value in Task { await model.setLeadDays(rule.kind, days: value) } }),
                                    in: 0...90) {
                                Text(L10n.string(Message("notifications.leadDays", [.integer(days)])))
                            }
                            .disabled(!rule.enabled)
                        }
                        if model.needsUnavailableData(rule.kind) {
                            Text("notifications.dividendDataUnavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("notifications.checkNow") { Task { await model.checkNow() } }.disabled(!model.authorized)
                if let count = model.lastCheckCount {
                    Text(L10n.string(Message("notifications.checked", [.integer(count)]))).font(.caption).foregroundStyle(.secondary)
                }
                Text("notifications.privacy").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { InlineMessage(message: error) }
            }
        }
        .formStyle(.grouped)
    }
}

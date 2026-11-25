import SwiftUI
import InvestiQCore
import InvestiQPresentation

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            SecuritySettingsView()
                .tabItem { Label("settings.tab.security", systemImage: "lock.shield") }
            DataProvidersSettingsView()
                .tabItem { Label("settings.tab.providers", systemImage: "network") }
            NotificationSettingsView()
                .tabItem { Label("settings.tab.notifications", systemImage: "bell") }
            AISettingsView()
                .tabItem { Label("settings.tab.ai", systemImage: "sparkles") }
            DataManagementView()
                .tabItem { Label("settings.tab.data", systemImage: "externaldrive") }
            LegalSettingsView()
                .tabItem { Label("settings.tab.legal", systemImage: "doc.text") }
        }
        .padding(Spacing.l)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Picker("settings.language", selection: Binding(
                get: { app.preferences.languageOverride ?? "" },
                set: { value in Task { try? await app.updatePreferences { $0.languageOverride = value.isEmpty ? nil : value } } })) {
                Text("settings.language.system").tag("")
                Text(verbatim: "Русский").tag("ru")
                Text(verbatim: "English").tag("en")
                Text(verbatim: "Čeština").tag("cs")
            }
            Picker("settings.baseCurrency", selection: Binding(
                get: { app.preferences.baseCurrency },
                set: { value in Task { try? await app.updatePreferences { $0.baseCurrency = value } } })) {
                ForEach(CurrencyCode.supportedBaseCurrencies, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("settings.colorBlindPalette", isOn: Binding(
                get: { app.preferences.colorBlindSafePalette },
                set: { value in Task { try? await app.updatePreferences { $0.colorBlindSafePalette = value } } }))
            Text("settings.colorBlindPalette.help").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(app.session == nil)
    }
}

private struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SecuritySettingsViewModel?

    var body: some View {
        Group {
            if app.isDemo {
                ContentUnavailableView("settings.security.demoUnavailable", systemImage: "theatermasks")
            } else if let model {
                SecurityForm(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = SecuritySettingsViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct SecurityForm: View {
    @Bindable var model: SecuritySettingsViewModel
    @Environment(AppModel.self) private var app
    @State private var confirmDeletion = false

    var body: some View {
        Form {
            Section("settings.security.lock") {
                Picker("settings.security.autoLock", selection: Binding(
                    get: { model.autoLockMinutes },
                    set: { minutes in Task { await model.setAutoLock(minutes: minutes) } })) {
                    ForEach(UserPreferences.autoLockChoices, id: \.self) { minutes in
                        Text(L10n.string(.init("settings.security.minutes", [.integer(minutes)]))).tag(minutes)
                    }
                }
                Toggle("settings.security.touchID", isOn: Binding(
                    get: { model.biometricEnabled },
                    set: { enabled in Task { await model.setBiometricUnlock(enabled) } }))
                    .disabled(model.biometricAvailability != .available)
                if model.biometricAvailability != .available {
                    Text(LocalizedStringKey("auth.error.biometric.\(model.biometricAvailability.localizationSuffix)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("menu.lock") { Task { await app.lock(reason: .manual) } }
            }
            Section("settings.security.changePassword") {
                SecureField("settings.security.currentPassword", text: $model.currentPassword)
                SecureField("settings.security.newPassword", text: $model.newPassword)
                SecureField("profile.passwordConfirmation", text: $model.newPasswordConfirmation)
                ForEach(model.newPasswordIssues, id: \.self) { issue in
                    Text(LocalizedStringKey("password.issue.\(issue.rawValue)")).font(.caption).foregroundStyle(.orange)
                }
                Button("settings.security.changePassword") { Task { await model.changePassword() } }
                    .disabled(model.isBusy || model.currentPassword.isEmpty || model.newPassword.isEmpty)
            }
            Section("settings.security.deleteProfile") {
                Text("settings.security.deleteProfile.warning").font(.callout).foregroundStyle(.secondary)
                SecureField("profile.password", text: $model.deletionPassword)
                Button("settings.security.deleteProfile", role: .destructive) { confirmDeletion = true }
                    .disabled(model.deletionPassword.isEmpty || model.isBusy)
            }
            if let message = model.message { InlineMessage(message: message, isError: false) }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("settings.security.deleteProfile.confirm"), isPresented: $confirmDeletion) {
            Button("settings.security.deleteProfile", role: .destructive) { Task { await model.deleteProfile() } }
            Button("common.cancel", role: .cancel) {}
        }
    }
}

private struct LegalSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("legal.title").font(.title2.bold())
                Text("disclaimer.notAdvice").fixedSize(horizontal: false, vertical: true)
                Text("legal.riskDisclosure").fixedSize(horizontal: false, vertical: true)
                Text("legal.investorProtection").fixedSize(horizontal: false, vertical: true)
                Text("legal.noTelemetry").fixedSize(horizontal: false, vertical: true)
                Text(L10n.string(.init("legal.version", [.text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")])))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.l)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}


import SwiftUI
import InvestiQPresentation

/// Settings → Data Providers (docs/DATA_PROVIDERS.md §5). Keys go to the Keychain and are never shown again.
struct DataProvidersSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: DataProvidersViewModel?

    var body: some View {
        Group {
            if app.isDemo {
                ContentUnavailableView("provider.demoOnly", systemImage: "theatermasks", description: Text("provider.demoOnly.detail"))
            } else if let model {
                ProvidersForm(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = DataProvidersViewModel(app: app) }
            await model?.load()
        }
    }
}

private struct ProvidersForm: View {
    @Bindable var model: DataProvidersViewModel

    var body: some View {
        Form {
            Section {
                Text("provider.intro").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.message { InlineMessage(message: message, isError: false) }
            }
            ForEach(model.rows) { row in
                Section {
                    ProviderRowView(row: row, model: model)
                } header: {
                    HStack {
                        Text(verbatim: row.name).font(.headline)
                        Spacer()
                        Button { Task { await model.move(row.id, by: -1) } } label: { Image(systemName: "arrow.up") }
                            .help(Text("provider.priorityUp"))
                        Button { Task { await model.move(row.id, by: 1) } } label: { Image(systemName: "arrow.down") }
                            .help(Text("provider.priorityDown"))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section("provider.sec.title") {
                Text("provider.sec.explanation").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("provider.sec.email", text: $model.secContactEmail)
                if !model.secEmailIsValid { Text("provider.secEmailInvalid").font(.caption).foregroundStyle(.orange) }
                Button("common.save") { Task { await model.saveSECEmail() } }.disabled(!model.secEmailIsValid)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderRowView: View {
    let row: DataProvidersViewModel.Row
    let model: DataProvidersViewModel
    @State private var keyInput = ""

    var body: some View {
        Text(LocalizedStringKey(row.coverageKey)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("provider.enabled", isOn: Binding(get: { row.enabled }, set: { value in Task { await model.setEnabled(row.id, value) } }))
            .disabled(row.requiresKey && !row.hasKey)
        if row.requiresKey {
            HStack {
                SecureField(LocalizedStringKey(row.hasKey ? "provider.keyStored" : "provider.keyPlaceholder"), text: $keyInput)
                Button("common.save") {
                    let key = keyInput
                    keyInput = ""
                    Task { await model.saveKey(key, for: row.id) }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if row.hasKey { Button("provider.removeKey", role: .destructive) { Task { await model.removeKey(for: row.id) } } }
            }
        }
        HStack {
            Button("provider.test") { Task { await model.testConnection(row.id) } }
                .disabled(!row.enabled || model.testingProviderID != nil)
            if model.testingProviderID == row.id { ProgressView().controlSize(.small) }
            Spacer()
            if let terms = row.termsURL { ExternalLinkButton(title: "provider.terms", url: terms) }
            if let signup = row.signupURL { ExternalLinkButton(title: "provider.signup", url: signup) }
        }
        if let success = row.lastSuccess {
            Text(L10n.string(.init("provider.lastSuccess", [.instant(success)]))).font(.caption2).foregroundStyle(.secondary)
        }
        if let failure = row.lastFailure {
            Text(L10n.string(.init("provider.lastFailure", [.instant(failure)]))).font(.caption2).foregroundStyle(.orange)
        }
    }
}

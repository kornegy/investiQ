import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Settings → AI (spec §24): off by default; external AI only after explicit consent; never for minors.
struct AISettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: AISettingsViewModel?

    var body: some View {
        Group {
            if let model { AISettingsContent(model: model) } else { ProgressView() }
        }
        .task {
            if model == nil { model = AISettingsViewModel(app: app) }
            model?.load()
        }
    }
}

private struct AISettingsContent: View {
    @Bindable var model: AISettingsViewModel
    @State private var consentPending = false
    @State private var keyText = ""

    var body: some View {
        Form {
            Section {
                Text("ai.settings.intro").fixedSize(horizontal: false, vertical: true)
                Picker("ai.settings.provider", selection: Binding(
                    get: { model.settings.provider },
                    set: { kind in
                        if kind == .externalAPI { consentPending = true } else { Task { await model.select(kind) } }
                    })) {
                    ForEach(model.availableProviders, id: \.self) { Text(LocalizedStringKey("ai.provider.\($0.rawValue)")).tag($0) }
                }
                if model.isEducationalMode { Text("ai.settings.educationalMode").font(.caption).foregroundStyle(.secondary) }
                if !model.onDeviceAvailable { Text("ai.settings.onDeviceUnavailable").font(.caption).foregroundStyle(.secondary) }
            }
            if model.settings.provider == .ollama {
                Section("ai.settings.ollama") {
                    TextField("ai.settings.endpoint", text: $model.ollamaEndpoint)
                    TextField("ai.settings.model", text: $model.modelName)
                    Button("common.save") { Task { await model.saveConnection() } }
                    Text("ai.settings.ollamaNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.settings.provider == .externalAPI {
                Section("ai.settings.external") {
                    SecureField("ai.settings.apiKey", text: $keyText)
                    Button("ai.settings.saveKey") { Task { await model.saveExternalKey(keyText); keyText = "" } }.disabled(keyText.isEmpty)
                    Text(LocalizedStringKey(model.hasExternalKey ? "ai.settings.keyStored" : "ai.settings.keyMissing")).font(.caption)
                    TextField("ai.settings.model", text: $model.modelName, prompt: Text(verbatim: model.defaultExternalModel))
                    Button("common.save") { Task { await model.saveConnection() } }
                    Toggle("ai.settings.portfolioContext", isOn: Binding(get: { model.settings.allowPortfolioContext },
                                                                        set: { value in Task { await model.setPortfolioContext(value) } }))
                    Text("ai.settings.whatIsSent").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Text("ai.settings.guarantees").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.message { InlineMessage(message: message, isError: message.key != "ai.keySaved") }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("ai.consent.title", isPresented: $consentPending, titleVisibility: .visible) {
            Button("ai.consent.agree") { Task { await model.select(.externalAPI, consented: true) } }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("ai.consent.body")
        }
    }
}

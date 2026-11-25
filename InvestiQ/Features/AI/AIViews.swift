import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// "Explain with AI" button for a fixed task. Hidden when AI is off; the answer appears in a sheet.
struct AIExplainButton: View {
    @Environment(AppModel.self) private var app
    let title: LocalizedStringKey
    let task: AITask
    @State private var model: AIAssistantViewModel?
    @State private var presented = false

    var body: some View {
        if app.services?.ai.isEnabled == true {
            Button {
                if model == nil { model = AIAssistantViewModel(app: app, languageName: AIAssistantViewModel.languageName(for: Bundle.main.preferredLocalizations.first)) }
                presented = true
                Task { await model?.run(task) }
            } label: { Label(title, systemImage: "sparkles") }
            .buttonStyle(.borderless)
            .sheet(isPresented: $presented) {
                if let model { AIAnswerSheet(model: model) }
            }
        }
    }
}

struct AIAnswerSheet: View {
    let model: AIAssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            AIAnswerContent(model: model)
            HStack { Spacer(); Button("common.ok") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 280)
    }
}

/// Plain-text rendering of a validated answer with its provenance and warnings (AI output is untrusted).
struct AIAnswerContent: View {
    let model: AIAssistantViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("ai.answer.title", systemImage: "sparkles").font(.headline)
            if model.isWorking { ProgressView().controlSize(.small) }
            if let error = model.error { InlineMessage(message: error) }
            if let answer = model.answer {
                Text(verbatim: answer.answer).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(answer.keyPoints, id: \.self) { point in
                    Label { Text(verbatim: point) } icon: { Image(systemName: "checkmark") }.font(.callout)
                }
                ForEach(answer.caveats, id: \.self) { caveat in
                    Label { Text(verbatim: caveat) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(AIOutputFlag.allCases.filter { answer.flags.contains($0) }, id: \.self) { flag in
                    Label(LocalizedStringKey("ai.flag.\(flag.rawValue)"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(LocalizedStringKey(answer.sentOffDevice ? "ai.provenance.external" : "ai.provenance.local"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("ai.disclaimer").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Free educational question box (Learn section).
struct AIQuestionBox: View {
    @Environment(AppModel.self) private var app
    @State private var model: AIAssistantViewModel?

    var body: some View {
        if app.services?.ai.isEnabled == true {
            Card {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    CardHeader(title: "ai.question.title", help: "ai.question.help")
                    if let model {
                        QuestionField(model: model)
                        AIAnswerContent(model: model)
                    }
                }
            }
            .task {
                if model == nil { model = AIAssistantViewModel(app: app, languageName: AIAssistantViewModel.languageName(for: Bundle.main.preferredLocalizations.first)) }
            }
        }
    }
}

private struct QuestionField: View {
    @Bindable var model: AIAssistantViewModel

    var body: some View {
        HStack {
            TextField("ai.question.placeholder", text: $model.question).textFieldStyle(.roundedBorder).onSubmit { Task { await model.askQuestion() } }
            Button("ai.question.ask") { Task { await model.askQuestion() } }.disabled(model.isWorking)
        }
        if model.sendsDataOffDevice {
            Text("ai.question.externalNote").font(.caption).foregroundStyle(.secondary)
        }
    }
}

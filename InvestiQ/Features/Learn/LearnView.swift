import SwiftUI
import InvestiQCore
import InvestiQContent
import InvestiQPresentation

/// Course (spec §20): learning path, lessons with analogies, calculators and short quizzes.
struct LearnView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LearnViewModel?
    @State private var lessonLanguage: String?

    var body: some View {
        Group {
            if let model { LearnContent(model: model) } else { ProgressView() }
        }
        .task(id: L10n.languageCode) {
            // Lessons follow the language the interface is shown in; switching it reloads them.
            let language = L10n.languageCode
            if model == nil || lessonLanguage != language {
                model = LearnViewModel(app: app, languageCode: language)
                lessonLanguage = language
            }
            await model?.load()
        }
    }
}

private struct LearnContent: View {
    @Bindable var model: LearnViewModel

    var body: some View {
        HStack(spacing: 0) {
            PathList(model: model)
                .frame(width: 300)
            Divider()
            if let lesson = model.selectedLesson {
                LessonView(model: model, lesson: lesson)
            } else {
                LearnOverview(model: model)
            }
        }
    }
}

private struct PathList: View {
    let model: LearnViewModel

    var body: some View {
        List(selection: Binding(get: { model.selectedLessonID },
                                set: { id in
                                    if let lesson = model.lessons.first(where: { $0.id == id }) { Task { await model.open(lesson) } }
                                })) {
            ForEach(LearnViewModel.stages, id: \.self) { stage in
                Section(L10n.key("learn.stage", String(stage))) {
                    ForEach(model.lessons(in: stage)) { lesson in
                        HStack {
                            Image(systemName: icon(model.status(of: lesson)))
                                .foregroundStyle(model.status(of: lesson) == .completed ? Color.green : Color.secondary)
                                .accessibilityLabel(Text(L10n.key("learn.status", model.status(of: lesson).rawValue)))
                            VStack(alignment: .leading) {
                                Text(lesson.title).lineLimit(2)
                                Text(L10n.string(Message("learn.minutes", [.integer(lesson.minutes)]))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(lesson.id)
                    }
                }
            }
        }
    }

    private func icon(_ status: LessonProgress.Status) -> String {
        switch status {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

private struct LearnOverview: View {
    let model: LearnViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("section.learn").font(.largeTitle.bold())
                Text("learn.intro").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { InlineMessage(message: error) }
                ProgressView(value: Double(model.completedCount), total: Double(max(1, model.lessons.count))) {
                    Text(L10n.string(Message("learn.progress", [.integer(model.completedCount), .integer(model.lessons.count)])))
                }
                if model.isCourseComplete {
                    Card {
                        Label("learn.complete", systemImage: "checkmark.seal")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let next = model.nextLesson {
                    Button {
                        Task { await model.open(next) }
                    } label: {
                        Label(L10n.string(Message("learn.next", [.text(next.title)])), systemImage: "arrow.right.circle")
                    }
                    .controlSize(.large)
                }
                Text("learn.notReadinessNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AIQuestionBox()
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct LessonView: View {
    @Bindable var model: LearnViewModel
    let lesson: Lesson

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Button { model.selectedLessonID = nil } label: { Label("learn.back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(lesson.title).font(.largeTitle.bold())
                AIExplainButton(title: "ai.explainTopic", task: .explainTerm(lesson.title))
                Text(lesson.summary).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(lesson.sections, id: \.heading) { section in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(section.heading).font(.title2.weight(.semibold))
                        Text(section.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Card {
                    Label { Text(lesson.analogy).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }
                        .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("learn.keyPoints").font(.headline)
                    ForEach(lesson.keyPoints, id: \.self) { point in
                        Label(point, systemImage: "checkmark").fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let calculator = lesson.calculator { CalculatorView(model: model, kind: calculator) }
                QuizView(model: model, lesson: lesson)
                Text("learn.generalNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct QuizView: View {
    @Bindable var model: LearnViewModel
    let lesson: Lesson

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: "learn.quiz.title")
                ForEach(Array(lesson.quiz.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(question.question).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Picker(question.question, selection: Binding(
                            get: { index < model.answers.count ? model.answers[index] : nil },
                            set: { if index < model.answers.count { model.answers[index] = $0 } })) {
                            ForEach(Array(question.options.enumerated()), id: \.offset) { option, text in
                                Text(text).tag(Optional(option))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .disabled(model.submittedScore != nil)
                        if model.submittedScore != nil, index < model.answers.count {
                            let correct = model.answers[index] == question.correctIndex
                            Label(question.explanation, systemImage: correct ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(correct ? Color.green : Color.orange)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let score = model.submittedScore {
                    Text(L10n.string(Message("learn.quiz.score", [.integer(score), .integer(lesson.quiz.count)]))).font(.headline)
                    Button("learn.quiz.retry") { model.retryQuiz() }
                } else {
                    Button("learn.quiz.check") { Task { await model.submitQuiz() } }.disabled(!model.canSubmit)
                }
            }
        }
    }
}

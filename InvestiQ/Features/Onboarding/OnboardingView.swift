import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Short onboarding questionnaire (spec §7). Answers are used only for safety education and
/// presentation, never to select instruments (docs/LEGAL_COMPLIANCE.md §2).
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var model: OnboardingViewModel?

    var body: some View {
        Group {
            if let model { OnboardingSteps(model: model) } else { ProgressView() }
        }
        .onAppear { if model == nil { model = OnboardingViewModel(app: app, locale: L10n.locale) } }
    }
}

private struct OnboardingSteps: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ProgressView(value: model.progress)
                .accessibilityLabel(Text("onboarding.progress"))
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) { stepContent }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.vertical, Spacing.l)
            }
            if let error = model.error { InlineMessage(message: error) }
            HStack {
                if model.step != .welcome { Button("common.back") { model.back() } }
                Spacer()
                if model.step == .summary {
                    Button("onboarding.finish") { Task { await model.finish() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canAdvance)
                        .accessibilityIdentifier("onboarding.finish")
                } else {
                    Button("common.continue") { model.next() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdvance)
                        .accessibilityIdentifier("onboarding.continue")
                }
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome:
            Text("onboarding.welcome.title").font(.largeTitle.bold())
            Text("onboarding.welcome.body").fixedSize(horizontal: false, vertical: true)
            Text("onboarding.welcome.privacy").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .residence:
            Text("onboarding.residence.title").font(.title.bold())
            Picker("onboarding.country", selection: $model.country) {
                ForEach(OnboardingViewModel.featuredCountries, id: \.self) { code in
                    Text(L10n.locale.localizedString(forRegionCode: code) ?? code).tag(code)
                }
            }
            Picker("onboarding.currency", selection: $model.currency) {
                ForEach(CurrencyCode.supportedBaseCurrencies, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        case .age:
            Text("onboarding.age.title").font(.title.bold())
            OptionPicker(selection: $model.ageCategory, options: AgeCategory.allCases, keyPrefix: "onboarding.age")
            Text("onboarding.age.minorNote").font(.callout).foregroundStyle(.secondary)
        case .knowledge:
            Text("onboarding.knowledge.title").font(.title.bold())
            OptionPicker(selection: $model.knowledgeLevel, options: KnowledgeLevel.allCases, keyPrefix: "onboarding.knowledge")
            Text("onboarding.experience.title").font(.title3.bold())
            OptionPicker(selection: $model.experience, options: InvestmentExperience.allCases, keyPrefix: "onboarding.experience")
            Text("onboarding.knowledge.note").font(.callout).foregroundStyle(.secondary)
        case .goals:
            Text("onboarding.goals.title").font(.title.bold())
            ForEach(FinancialGoal.allCases, id: \.self) { goal in
                Toggle(LocalizedStringKey("onboarding.goal.\(goal.rawValue)"), isOn: Binding(
                    get: { model.goals.contains(goal) },
                    set: { isOn in if isOn { model.goals.insert(goal) } else { model.goals.remove(goal) } }))
            }
            Text("onboarding.horizon.title").font(.title3.bold())
            OptionPicker(selection: $model.horizon, options: InvestmentHorizon.allCases, keyPrefix: "onboarding.horizon")
        case .finances:
            Text("onboarding.finances.title").font(.title.bold())
            Text("onboarding.income.title").font(.title3.bold())
            OptionPicker(selection: $model.incomeStability, options: IncomeStability.allCases, keyPrefix: "onboarding.income")
            TextField("onboarding.essentialExpenses", text: $model.essentialExpensesText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            if model.essentialExpensesInvalid {
                Text("validation.invalidAmount").font(.caption).foregroundStyle(.orange)
            }
            Text("onboarding.emergencyFund.title").font(.title3.bold())
            OptionPicker(selection: $model.emergencyFund, options: EmergencyFundStatus.allCases, keyPrefix: "onboarding.emergencyFund")
            Text("onboarding.debt.title").font(.title3.bold())
            OptionPicker(selection: $model.debtStatus, options: DebtStatus.allCases, keyPrefix: "onboarding.debt")
        case .risk:
            Text("onboarding.risk.title").font(.title.bold())
            Text("onboarding.risk.question").fixedSize(horizontal: false, vertical: true)
            OptionPicker(selection: $model.riskAttitude, options: RiskAttitude.allCases, keyPrefix: "onboarding.risk")
            Text("onboarding.risk.note").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .summary:
            Text("onboarding.summary.title").font(.title.bold())
            if model.willEnableEducationalMode {
                Label("onboarding.summary.educationalMode", systemImage: "graduationcap").foregroundStyle(.purple)
            }
            if model.safetyNotes.isEmpty {
                Text("onboarding.summary.noNotes")
            } else {
                ForEach(model.safetyNotes, id: \.self) { note in
                    Card {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(LocalizedStringKey("safety.\(note.rawValue).title")).font(.headline)
                            Text(LocalizedStringKey("safety.\(note.rawValue).body")).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            GeneralInformationNote()
        }
    }
}

/// Radio-style picker over an enum whose labels are `"<prefix>.<rawValue>"` localisation keys.
struct OptionPicker<Option: RawRepresentable & Hashable>: View where Option.RawValue == String {
    @Binding var selection: Option?
    let options: [Option]
    let keyPrefix: String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(LocalizedStringKey("\(keyPrefix).\(option.rawValue)")).tag(Optional(option))
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }
}

import SwiftUI
import InvestiQSecurity
import InvestiQPresentation

struct CreateProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateProfileViewModel?

    var body: some View {
        Group {
            if let model { CreateProfileForm(model: model, dismiss: { dismiss() }) } else { ProgressView() }
        }
        .frame(width: 480)
        .onAppear { if model == nil { model = CreateProfileViewModel(app: app) } }
    }
}

private struct CreateProfileForm: View {
    @Bindable var model: CreateProfileViewModel
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("profile.displayName", text: $model.displayName)
                    .accessibilityIdentifier("profile.displayName")
                SecureField("profile.password", text: $model.password)
                    .accessibilityIdentifier("profile.password")
                SecureField("profile.passwordConfirmation", text: $model.confirmation)
                    .accessibilityIdentifier("profile.passwordConfirmation")
            } header: {
                Text("profile.create.title").font(.title2.bold())
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    PasswordStrengthMeter(strength: model.strength, isEmpty: model.password.isEmpty)
                    ForEach(model.issues, id: \.self) { issue in
                        Label(L10n.key("password.issue", issue.rawValue), systemImage: "xmark.circle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    Text("profile.create.passwordWarning").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.error { InlineMessage(message: error) }
            HStack {
                Button("common.cancel", role: .cancel, action: dismiss)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("profile.create.submit") { Task { await model.submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("profile.create.submit")
            }
        }
        .formStyle(.grouped)
        .padding(Spacing.l)
    }
}

struct PasswordStrengthMeter: View {
    let strength: PasswordStrength
    let isEmpty: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            ProgressView(value: isEmpty ? 0 : Double(strength.rawValue + 1), total: Double(PasswordStrength.allCases.count))
                .tint(strength >= .good ? .green : .orange)
                .frame(width: 140)
            if !isEmpty { Text(L10n.key("password.strength", strength.label)).font(.caption) }
        }
        .accessibilityElement(children: .combine)
    }
}

extension PasswordStrength {
    var label: String {
        switch self {
        case .weak: return "weak"
        case .fair: return "fair"
        case .good: return "good"
        case .strong: return "strong"
        }
    }
}

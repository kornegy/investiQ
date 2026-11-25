import SwiftUI
import InvestiQPresentation

struct LockScreenView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LockScreenViewModel?
    @State private var showCreateProfile = false

    var body: some View {
        Group {
            if let model { LockForm(model: model, showCreateProfile: $showCreateProfile) } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if model == nil { model = LockScreenViewModel(app: app) }
            await model?.onAppear()
        }
        .sheet(isPresented: $showCreateProfile) { CreateProfileView() }
    }
}

private struct LockForm: View {
    @Bindable var model: LockScreenViewModel
    @Binding var showCreateProfile: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("lock.title").font(.title.bold())
            if let reason = app.lastLockReason {
                Text(LocalizedStringKey("lock.reason.\(reason.rawValue)")).foregroundStyle(.secondary)
            }
            Form {
                Picker("lock.profile", selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }
                .onChange(of: model.selectedProfileID) { _, _ in Task { await model.refreshStatus() } }
                SecureField("profile.password", text: $model.password)
                    .onSubmit { Task { await model.unlock() } }
                    .disabled(model.isLockedOut)
                    .accessibilityIdentifier("lock.password")
            }
            .formStyle(.grouped)
            .frame(width: 420)

            if let until = model.lockedUntil, model.isLockedOut {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(until.timeIntervalSince(context.date)))
                    Text(L10n.string(.init("lock.lockedOutCountdown", [.integer(remaining)])))
                        .foregroundStyle(.orange)
                        .task(id: remaining == 0) { if remaining == 0 { await model.refreshStatus() } }
                }
            } else if let error = model.error {
                InlineMessage(message: error)
            }

            HStack(spacing: Spacing.m) {
                if model.biometricEnabledForSelection {
                    Button {
                        Task { await model.unlockWithBiometrics(reason: L10n.string("lock.touchIDReason")) }
                    } label: { Label("lock.touchID", systemImage: "touchid") }
                }
                Button("lock.unlock") { Task { await model.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("lock.unlock")
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            Button("lock.createAnotherProfile") { showCreateProfile = true }.buttonStyle(.link)
        }
        .padding(Spacing.xxl)
    }
}

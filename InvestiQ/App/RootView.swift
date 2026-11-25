import SwiftUI
import InvestiQCore
import InvestiQPresentation

/// Switches between the top-level states of `AppModel` (docs/ARCHITECTURE.md §3.1).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var monitor = SystemEventMonitor()

    /// Inactivity is checked periodically; this is a cheap timer, not data polling.
    private let autoLockCheckInterval: Duration = .seconds(30)

    var body: some View {
        Group {
            switch app.state {
            case .loading:
                ProgressView("common.loading")
            case .welcome:
                WelcomeView()
            case .locked:
                LockScreenView()
            case .onboarding:
                OnboardingView()
            case .unlocked:
                MainView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("app.error.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.string(message))
                } actions: {
                    Button("common.retry") { Task { await app.bootstrap() } }
                }
            }
        }
        .environment(\.palette, Palette(colorBlindSafe: app.preferences.colorBlindSafePalette))
        .environment(\.locale, L10n.locale)
        .task {
            L10n.languageOverride = app.preferences.languageOverride
            await app.bootstrap()
            monitor.start(app: app)
            while !Task.isCancelled {
                try? await Task.sleep(for: autoLockCheckInterval)
                await app.checkAutoLock()
            }
        }
        .onChange(of: app.preferences.languageOverride) { _, newValue in L10n.languageOverride = newValue }
    }
}

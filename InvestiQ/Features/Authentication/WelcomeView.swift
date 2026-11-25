import SwiftUI
import InvestiQPresentation

/// First launch: create a local profile or explore the demo (FR-AUTH-1, FR-DEMO).
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showCreateProfile = false

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("welcome.title").font(.largeTitle.bold())
            Text("welcome.subtitle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label("welcome.point.local", systemImage: "lock.shield")
                Label("welcome.point.noAdvice", systemImage: "hand.raised")
                Label("welcome.point.sources", systemImage: "doc.text.magnifyingglass")
            }
            .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: Spacing.m) {
                Button("welcome.createProfile") { showCreateProfile = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.createProfile")
                Button("welcome.tryDemo") { Task { await app.startDemo() } }
                    .accessibilityIdentifier("welcome.tryDemo")
            }
            Text("disclaimer.notAdvice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCreateProfile) { CreateProfileView() }
    }
}

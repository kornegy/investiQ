import SwiftUI
import InvestiQPresentation

/// Menu commands and keyboard shortcuts (⌘L lock, ⌘1…⌘0 sections).
struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu(Text("menu.account")) {
            Button("menu.lock") { Task { await app.lock(reason: .manual) } }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(app.state != .unlocked && app.state != .onboarding)
        }
        CommandMenu(Text("menu.navigate")) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(LocalizedStringKey(section.titleKey)) { app.selectedSection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: [.command])
                    .disabled(app.state != .unlocked)
            }
        }
    }
}

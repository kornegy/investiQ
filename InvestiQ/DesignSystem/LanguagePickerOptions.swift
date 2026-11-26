import SwiftUI
import InvestiQCore

/// Picker rows for the interface language: "System language" (tag `""`) and every supported language.
/// Language names are written in their own language so anyone can find theirs, whatever is shown now.
struct LanguagePickerOptions: View {
    private static let nativeNames = ["ru": "Русский", "en": "English", "cs": "Čeština"]

    var body: some View {
        Text("settings.language.system").tag("")
        ForEach(UserPreferences.supportedLanguages, id: \.self) { code in
            Text(verbatim: Self.nativeNames[code] ?? code).tag(code)
        }
    }
}

import AppKit
import SwiftUI
import InvestiQSecurity

/// Opens external links only after showing the real destination host and any warnings
/// (spec §26, docs/SECURITY.md §7). Uses the default system browser.
struct ExternalLinkButton: View {
    let title: LocalizedStringKey
    let url: URL
    @State private var inspection: LinkInspection?
    @State private var rejected = false

    var body: some View {
        Button {
            switch LinkSafety.inspect(url) {
            case .success(let result): inspection = result
            case .failure: rejected = true
            }
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
        }
        .confirmationDialog(Text("link.confirm.title"), isPresented: Binding(
            get: { inspection != nil }, set: { if !$0 { inspection = nil } }
        ), presenting: inspection) { result in
            Button("link.confirm.open") { NSWorkspace.shared.open(result.url) }
            Button("common.cancel", role: .cancel) {}
        } message: { result in
            Text(LinkConfirmationText.describe(result))
        }
        .alert(Text("link.rejected"), isPresented: $rejected) {
            Button("common.ok", role: .cancel) {}
        }
    }
}

@MainActor
enum LinkConfirmationText {
    static func describe(_ inspection: LinkInspection) -> String {
        var lines = [L10n.string(.init("link.confirm.destination", [.text(inspection.displayHost)]))]
        if inspection.displayHost != inspection.asciiHost {
            lines.append(L10n.string(.init("link.confirm.technicalHost", [.text(inspection.asciiHost)])))
        }
        for warning in inspection.warnings { lines.append("⚠︎ " + L10n.string("link.warning.\(warning.rawValue)")) }
        return lines.joined(separator: "\n")
    }
}

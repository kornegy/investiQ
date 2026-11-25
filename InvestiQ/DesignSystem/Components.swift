import SwiftUI
import InvestiQCore

/// A rounded content container.
struct Card<Content: View>: View {
    @Environment(\.palette) private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(palette.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.separator.opacity(0.6)))
    }
}

/// Card title with an optional help tooltip explaining the metric in plain language.
struct CardHeader: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(title).font(.headline)
            if let help { InfoTooltip(text: help) }
            Spacer()
        }
    }
}

/// Small ⓘ button: hover shows a tooltip, click shows a popover (keyboard- and VoiceOver-accessible).
struct InfoTooltip: View {
    let text: LocalizedStringKey
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(Text("a11y.moreInfo"))
        .popover(isPresented: $isPresented) {
            Text(text).padding(Spacing.l).frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Direction of a change. Communicated with sign, arrow glyph and colour (never colour alone).
enum ChangeDirection {
    case up, down, flat

    init(_ value: Decimal?) {
        guard let value else { self = .flat; return }
        self = value > 0 ? .up : (value < 0 ? .down : .flat)
    }

    var glyph: String {
        switch self {
        case .up: return "▲"
        case .down: return "▼"
        case .flat: return "–"
        }
    }

    var accessibilityKey: LocalizedStringKey {
        switch self {
        case .up: return "a11y.change.up"
        case .down: return "a11y.change.down"
        case .flat: return "a11y.change.flat"
        }
    }
}

struct ChangeLabel: View {
    @Environment(\.palette) private var palette
    let direction: ChangeDirection
    let text: String

    var body: some View {
        HStack(spacing: 2) {
            Text(direction.glyph).font(.caption2)
            Text(text).font(.tableNumber)
        }
        .foregroundStyle(direction == .up ? palette.positive : direction == .down ? palette.negative : palette.neutral)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(direction.accessibilityKey) + Text(" ") + Text(text))
    }
}

/// Headline number with label, optional change and tooltip.
struct MetricTile: View {
    let title: LocalizedStringKey
    let value: String
    var change: (ChangeDirection, String)?
    var help: LocalizedStringKey?
    var footnote: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: title, help: help)
                Text(value).font(.metricValue).lineLimit(1).minimumScaleFactor(0.6)
                if let change { ChangeLabel(direction: change.0, text: change.1) }
                if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows the timeliness of a value. Free/cached data is never labelled real-time.
struct FreshnessBadge: View {
    @Environment(\.palette) private var palette
    let delay: DelayStatus

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var title: String {
        switch delay {
        case .realtime: return L10n.string("delay.realtime")
        case .delayed(let minutes): return L10n.string(Message("delay.delayedMinutes", [.integer(minutes)]))
        case .endOfDay: return L10n.string("delay.endOfDay")
        case .cached: return L10n.string("delay.cached")
        case .stale: return L10n.string("delay.stale")
        case .manual: return L10n.string("delay.manual")
        case .synthetic: return L10n.string("delay.synthetic")
        }
    }

    private var symbol: String {
        switch delay {
        case .realtime: return "dot.radiowaves.left.and.right"
        case .delayed, .endOfDay: return "clock"
        case .cached: return "tray.full"
        case .stale: return "exclamationmark.triangle"
        case .manual: return "pencil"
        case .synthetic: return "theatermasks"
        }
    }

    private var color: Color {
        switch delay {
        case .stale: return palette.warning
        case .synthetic: return .purple
        default: return palette.info
        }
    }
}

/// Source + time footer for any data card (spec §15).
struct SourceFooter: View {
    let metadata: DataMetadata

    var body: some View {
        HStack(spacing: Spacing.s) {
            FreshnessBadge(delay: metadata.delay)
            Text(L10n.string(Message("source.footer", [.text(metadata.source.name), .instant(metadata.retrievedAt)])))
                .font(.caption).foregroundStyle(.secondary)
            if metadata.quality == .conflicting {
                Label("quality.conflicting", systemImage: "exclamationmark.2").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct StatusBadge: View {
    @Environment(\.palette) private var palette
    let status: AnalyticalStatus

    var body: some View {
        Text(LocalizedStringKey(status.messageKey))
            .font(.caption.weight(.medium))
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .elevatedRisk: return palette.warning
        case .insufficientData, .elevatedUncertainty: return .secondary
        case .metricsWarrantReview: return palette.warning
        case .furtherResearchRequired: return palette.info
        }
    }
}

/// Persistent banner shown in demo mode (ADR-008).
struct DemoBanner: View {
    var body: some View {
        Label("demo.banner", systemImage: "theatermasks")
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(Spacing.s)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(.purple)
            .accessibilityAddTraits(.isHeader)
    }
}

struct InlineMessage: View {
    let message: Message
    var isError = true

    var body: some View {
        Label(L10n.string(message), systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(isError ? Color.orange : Color.secondary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Standard "general information" disclaimer shown at the end of analytical screens (docs/UI_UX.md §6).
struct GeneralInformationNote: View {
    var body: some View {
        Text("disclaimer.generalInformation")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import Foundation
import Observation
import InvestiQCore

/// Observable, so every view that formats text through `L10n` re-renders as soon as the language changes
/// (onboarding's first step or Settings), not only on its next unrelated update.
@MainActor
@Observable
private final class InterfaceLanguageState {
    var override: String?
}

/// Resolves `Message` descriptors from the business layer into localised text (ADR-012).
@MainActor
enum L10n {
    private static let state = InterfaceLanguageState()

    /// Language chosen in onboarding or Settings (`nil` = system language).
    static var languageOverride: String? {
        get { state.override }
        set { if state.override != newValue { state.override = newValue } }
    }

    /// Language the interface is shown in: the chosen one, else the best match among the system languages.
    /// Lessons and AI answers follow it.
    static var languageCode: String? { languageOverride ?? Bundle.main.preferredLocalizations.first }

    static func locale(for languageOverride: String?) -> Locale {
        languageOverride.map(Locale.init(identifier:)) ?? .current
    }

    static var locale: Locale { locale(for: languageOverride) }

    private static var bundle: Bundle {
        if let language = languageOverride,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func string(_ message: Message) -> String {
        let template = string(message.key)
        guard !message.arguments.isEmpty else { return template }
        let arguments: [any CVarArg] = message.arguments.map { format(argument: $0) }
        return String(format: template, locale: locale, arguments: arguments)
    }

    static func format(argument: MessageArgument) -> String {
        switch argument {
        case .text(let text): return text
        case .integer(let value): return value.formatted(.number.locale(locale))
        case .decimal(let value, let digits):
            return value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        case .percent(let value, let digits):
            return value.formatted(.percent.precision(.fractionLength(digits)).locale(locale))
        case .money(let money): return Formatters.money(money)
        case .date(let date): return Formatters.date(date)
        case .instant(let instant): return instant.formatted(.dateTime.day().month().year().hour().minute().locale(locale))
        case .key(let key): return string(key)
        }
    }
}

/// Locale-aware formatting of domain values (docs/UI_UX.md §4).
@MainActor
enum Formatters {
    static func money(_ money: Money, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? money.currency.minorUnits
        return money.amount.formatted(.currency(code: money.currency.rawValue)
            .precision(.fractionLength(digits)).locale(L10n.locale))
    }

    /// Unknown currency is shown as a plain number — never guessed.
    static func money(_ amount: Decimal?, _ currency: CurrencyCode?) -> String {
        guard let amount else { return L10n.string("value.missing") }
        guard let currency else { return decimal(amount) }
        return money(Money(amount, currency))
    }

    static func decimal(_ value: Decimal?, fractionDigits: Int = 2) -> String {
        guard let value else { return L10n.string("value.missing") }
        return value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(L10n.locale))
    }

    static func percent(_ fraction: Double?, fractionDigits: Int = 2) -> String {
        guard let fraction, fraction.isFinite else { return L10n.string("value.missing") }
        return fraction.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(L10n.locale))
    }

    static func date(_ date: LocalDate) -> String {
        date.startOfDay(in: .current).formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
    }

    static func instant(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))
    }
}

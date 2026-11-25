import Foundation

/// Helpers for exact decimal arithmetic. Accounting code uses `Decimal` exclusively
/// (docs/FINANCIAL_METHODOLOGY.md §0); `Double` is only produced at the statistics boundary.
public enum DecimalSupport {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Strict parser for canonical decimal strings (`-12.345`, `1e-4`).
    /// `Decimal(string:)` alone accepts trailing garbage (`"12abc"` → 12), so the format is checked first.
    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCanonicalNumber(trimmed) else { return nil }
        return Decimal(string: trimmed, locale: posix)
    }

    /// Parses a number written by a human in a given locale (e.g. "1 234,56" in cs_CZ).
    public static func parse(_ text: String, locale: Locale) -> Decimal? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let grouping = locale.groupingSeparator ?? ","
        let decimal = locale.decimalSeparator ?? "."
        // Remove grouping separators, including the narrow/no-break spaces used by cs/ru locales.
        for separator in [grouping, "\u{00A0}", "\u{202F}", " "] where separator != decimal {
            cleaned = cleaned.replacingOccurrences(of: separator, with: "")
        }
        if decimal != "." { cleaned = cleaned.replacingOccurrences(of: decimal, with: ".") }
        return parse(cleaned)
    }

    static func isCanonicalNumber(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        var index = 0
        if scalars[index] == "-" || scalars[index] == "+" { index += 1 }
        var digitsBefore = 0
        while index < scalars.count, CharacterSet.decimalDigitsASCII.contains(scalars[index]) { index += 1; digitsBefore += 1 }
        var digitsAfter = 0
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, CharacterSet.decimalDigitsASCII.contains(scalars[index]) { index += 1; digitsAfter += 1 }
        }
        guard digitsBefore + digitsAfter > 0 else { return false }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
            var expDigits = 0
            while index < scalars.count, CharacterSet.decimalDigitsASCII.contains(scalars[index]) { index += 1; expDigits += 1 }
            guard expDigits > 0 else { return false }
        }
        scalars.removeAll()
        return index == text.unicodeScalars.count
    }
}

extension CharacterSet {
    static let decimalDigitsASCII = CharacterSet(charactersIn: "0123456789")
}

public extension Decimal {
    /// Locale-independent representation used for storage (`.` separator, no grouping).
    var canonicalString: String { description }

    /// Rounds to `scale` fractional digits. Default mode: half away from zero (`.plain`).
    func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var input = self
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    /// Conversion at the statistics boundary. Never convert the result back into ledger values.
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }

    var isNegativeValue: Bool { self < 0 }

    /// Absolute value (Decimal has no `abs` overload on all toolchains).
    var magnitudeValue: Decimal { self < 0 ? -self : self }

    /// Converts a finite `Double` to `Decimal` via its shortest decimal representation.
    /// Used only for *derived, non-accounting* values (e.g. a statistical estimate shown as money).
    init?(finite double: Double) {
        guard double.isFinite else { return nil }
        guard let value = DecimalSupport.parse(String(double)) else { return nil }
        self = value
    }
}

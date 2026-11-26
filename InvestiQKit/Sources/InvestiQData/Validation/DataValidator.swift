import Foundation
import InvestiQCore

/// Plausibility checks for provider data (docs/SECURITY.md §6, THREAT_MODEL T5/T6).
public enum DataValidator {
    /// Upper bound for a single price; rejects obvious garbage (e.g. 1e30) without biasing real data.
    static let maximumPlausiblePrice: Decimal = 100_000_000
    /// Market timestamps more than this in the future are rejected.
    static let futureTolerance: TimeInterval = 36 * 3600

    public static func validate(_ quote: Quote, marketTimestamp: Date?, now: Date) throws {
        guard quote.price > 0, quote.price < maximumPlausiblePrice else {
            throw ProviderFailure.invalidResponse("implausible price")
        }
        if let timestamp = marketTimestamp, timestamp.timeIntervalSince(now) > futureTolerance {
            throw ProviderFailure.invalidResponse("market timestamp in the future")
        }
        if let high = quote.dayHigh, let low = quote.dayLow, high < low {
            throw ProviderFailure.invalidResponse("day high below day low")
        }
    }

    /// Cleans a series: removes duplicates, future dates and inconsistent bars. Returns the cleaned
    /// series and how many bars were dropped (reported as `partial` quality when > 0).
    public static func clean(_ series: PriceSeries, today: LocalDate) -> (series: PriceSeries, dropped: Int) {
        var seen = Set<LocalDate>()
        var kept: [PriceBar] = []
        var dropped = 0
        for bar in series.bars.sorted(by: { $0.date < $1.date }) {
            guard bar.date <= today.adding(days: 1), !seen.contains(bar.date), isConsistent(bar) else {
                dropped += 1
                continue
            }
            seen.insert(bar.date)
            kept.append(bar)
        }
        var cleaned = series
        cleaned.bars = kept
        return (cleaned, dropped)
    }

    static func isConsistent(_ bar: PriceBar) -> Bool {
        guard bar.close > 0, bar.close < maximumPlausiblePrice else { return false }
        if let volume = bar.volume, volume < 0 { return false }
        let values = [bar.open, bar.close, bar.high, bar.low].compactMap { $0 }
        guard values.allSatisfy({ $0 > 0 }) else { return false }
        if let high = bar.high, values.contains(where: { $0 > high }) { return false }
        if let low = bar.low, values.contains(where: { $0 < low }) { return false }
        return true
    }

    public static func validate(_ rates: [ExchangeRate]) throws {
        for rate in rates where !(rate.rate > 0) {
            throw ProviderFailure.invalidResponse("non-positive exchange rate \(rate.base)/\(rate.quote)")
        }
    }
}

/// Compares the same value from two sources (spec §15: warn on conflicts).
public enum ConflictDetector {
    /// Relative difference above which two quotes for the same day are considered conflicting.
    public static let defaultTolerance: Decimal = 0.01

    public static func isConflicting(_ a: Decimal, _ b: Decimal, tolerance: Decimal = defaultTolerance) -> Bool {
        let reference = max(a.magnitudeValue, b.magnitudeValue)
        guard reference > 0 else { return false }
        return (a - b).magnitudeValue / reference > tolerance
    }
}

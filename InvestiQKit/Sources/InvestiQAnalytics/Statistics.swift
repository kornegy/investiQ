import Foundation

/// Descriptive statistics on `Double` (statistics boundary — docs/FINANCIAL_METHODOLOGY.md §0).
public enum Statistics {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n − 1).
    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let m = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    /// Linear-interpolation quantile (type 7, as in R/NumPy default), `p` in [0, 1].
    public static func quantile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty, (0...1).contains(p) else { return nil }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    public static func covariance(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 2, let ma = mean(a), let mb = mean(b) else { return nil }
        var sum = 0.0
        for i in a.indices { sum += (a[i] - ma) * (b[i] - mb) }
        return sum / Double(a.count - 1)
    }

    /// Pearson correlation; `nil` when either series has zero variance.
    public static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        guard let cov = covariance(a, b), let sa = standardDeviation(a), let sb = standardDeviation(b), sa > 0, sb > 0 else { return nil }
        return max(-1, min(1, cov / (sa * sb)))
    }
}

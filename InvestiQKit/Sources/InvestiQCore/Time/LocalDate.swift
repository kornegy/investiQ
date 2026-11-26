import Foundation

/// A calendar date without time or time zone (trade dates, market dates, maturities).
///
/// Uses the proleptic Gregorian calendar with Howard Hinnant's days-from-civil algorithm, so date
/// arithmetic is exact and independent of the device time zone (no DST surprises).
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), year >= 1, year <= 9999,
              day >= 1, day <= LocalDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD` (optionally followed by a time component, which is ignored).
    public init?(iso text: String) {
        let datePart = text.prefix(10)
        let parts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard datePart.count == 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01 (negative before).
    public init(daysSinceEpoch: Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.year = y
        self.month = m
        self.day = d
    }

    public var daysSinceEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    public var isLastDayOfMonth: Bool { day == LocalDate.daysInMonth(year: year, month: month) }

    public func adding(days: Int) -> LocalDate { LocalDate(daysSinceEpoch: daysSinceEpoch + days) }

    /// Adds calendar months, clamping the day to the target month's length.
    public func adding(months: Int) -> LocalDate {
        let total = (year * 12 + (month - 1)) + months
        let newYear = total / 12
        let newMonth = total % 12 + 1
        let newDay = min(day, LocalDate.daysInMonth(year: newYear, month: newMonth))
        // Force-unwrap is safe: month and day are clamped into the valid range above.
        return LocalDate(year: newYear, month: newMonth, day: newDay)!
    }

    public func adding(years: Int) -> LocalDate { adding(months: years * 12) }

    /// Number of days from `self` to `other` (positive if `other` is later).
    public func days(to other: LocalDate) -> Int { other.daysSinceEpoch - daysSinceEpoch }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        // 1970-01-01 was a Thursday (ISO 4).
        let value = (daysSinceEpoch % 7 + 7) % 7 // 0 = Thursday
        return (value + 3) % 7 + 1
    }

    public var isWeekend: Bool { isoWeekday >= 6 }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool { lhs.daysSinceEpoch < rhs.daysSinceEpoch }

    /// The calendar date of `instant` in `timeZone`.
    public init(_ instant: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        // Calendar always returns valid components for a finite Date.
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)!
    }

    /// Midnight at the start of this date in `timeZone`.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: TimeInterval(daysSinceEpoch) * 86_400)
    }

    /// Previous weekday (skips Saturday/Sunday; exchange holidays are not modelled here).
    public var previousWeekday: LocalDate {
        var date = adding(days: -1)
        while date.isWeekend { date = date.adding(days: -1) }
        return date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = LocalDate(iso: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(raw)'")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}

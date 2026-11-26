import Foundation

/// Directory entry (spec §19). Every field is either verified (with sources and a date) or `nil`, which
/// the UI shows as "not verified" — nothing is filled in from assumptions.
public struct BrokerEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Licence: String, Codable, Sendable, CaseIterable { case bankAndInvestmentFirm, investmentFirm }
    public enum CzechPresence: String, Codable, Sendable, CaseIterable { case czechCompany, czechBranch, crossBorder, unknown }

    /// Compensation if the intermediary fails — never protection against market losses.
    public struct InvestorProtection: Codable, Sendable, Hashable {
        public var scheme: String
        public var coveragePercent: Int?
        public var capEUR: Int?
        public var note: String?
    }

    public var id: String
    public var brand: String
    public var legalName: String
    /// ISO 3166-1 alpha-2 country of registration.
    public var country: String
    public var regulator: String
    public var licence: Licence
    public var registerURL: URL
    public var czechPresence: CzechPresence
    public var investorProtection: InvestorProtection?
    /// Deposit insurance for cash held by a bank (separate from investor compensation).
    public var depositProtectionCapEUR: Int?
    public var websiteURL: URL?
    // Fields that change often and were not verified are intentionally absent (nil): fees, currency
    // conversion fees, minimums, age limits, available instruments.
    public var fees: String?
    public var fxFees: String?
    public var minimumDeposit: String?
    public var minimumAge: Int?
    public var instrumentTypes: [String]?
    public var openQuestionKeys: [String]?
    public var sources: [URL]
    public var verifiedOn: LocalDate
}

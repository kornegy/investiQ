import InvestiQCore

/// SwiftUI declares its own `Transaction` (animation transaction); the app refers to ledger
/// transactions through this alias to avoid ambiguity.
typealias LedgerTransaction = InvestiQCore.Transaction

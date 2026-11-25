import Foundation
import InvestiQCore
import InvestiQData

/// Builds a synthetic demo portfolio from the demo universe (ADR-008). Prices are the synthetic
/// closes of the trade date; before a split the *raw* (unadjusted) price is used, as a real broker
/// statement would show, so the split transaction is exercised.
public enum DemoPortfolioSeeder {
    public static let portfolioName = "Demo portfolio"

    struct Purchase { let index: Int; let date: LocalDate; let quantity: Decimal }

    public static func transactions(portfolioID: PortfolioID, baseCurrency: CurrencyCode, today: LocalDate, createdAt: Date) -> [Transaction] {
        let universe = DemoUniverse.all
        var result: [Transaction] = []
        var sequence = 0.0
        func make(_ type: TransactionType, _ date: LocalDate, _ build: (inout Transaction) -> Void) {
            sequence += 1
            var t = Transaction(portfolioID: portfolioID, type: type, tradeDate: date, currency: baseCurrency, source: .demo,
                                createdAt: createdAt.addingTimeInterval(sequence))
            build(&t)
            result.append(t)
        }
        func fxToBase(_ currency: CurrencyCode, _ date: LocalDate) -> Decimal? {
            guard let quote = DemoUniverse.euroRate(baseCurrency, on: date), let from = DemoUniverse.euroRate(currency, on: date) else { return nil }
            return (quote / from).rounded(scale: 6)
        }
        func rawClose(_ demo: DemoInstrument, _ date: LocalDate) -> Decimal? {
            guard let bar = DemoUniverse.history(for: demo, through: date).last else { return nil }
            // Undo the adjustment of splits that happen after `date`.
            var factor: Decimal = 1
            for split in demo.splits where split.effectiveDate > date {
                factor *= Decimal(split.ratioNumerator ?? 1) / Decimal(split.ratioDenominator ?? 1)
            }
            return (bar.close * factor).rounded(scale: 2)
        }

        let start = max(LocalDate(year: 2020, month: 3, day: 2)!, today.adding(years: -6))
        make(.deposit, start) { $0.amount = 500_000 }
        let purchases = [Purchase(index: 0, date: start.adding(days: 10), quantity: 80),     // Demo Energie (CZK)
                         Purchase(index: 7, date: start.adding(days: 12), quantity: 900),    // World ETF (EUR)
                         Purchase(index: 5, date: start.adding(days: 30), quantity: 60),     // Demo Chips (USD) — before splits
                         Purchase(index: 10, date: start.adding(days: 40), quantity: 3),     // CZ government bond
                         Purchase(index: 4, date: start.adding(months: 14), quantity: 40)]   // Demo Consumer (USD)
        for purchase in purchases where purchase.date < today {
            let demo = universe[purchase.index]
            let date = purchase.date.isWeekend ? purchase.date.previousWeekday : purchase.date
            guard let price = rawClose(demo, date) else { continue }
            let currency = demo.listing.tradingCurrency
            let unitPrice = demo.bond.map { price / 100 * $0.faceValue } ?? price
            if currency != baseCurrency, let rate = fxToBase(currency, date) {
                make(.fxConversion, date) {
                    $0.amount = (purchase.quantity * unitPrice * rate * Decimal(string: "1.01")!).rounded(scale: 2)
                    $0.counterCurrency = currency
                    $0.counterAmount = (purchase.quantity * unitPrice * Decimal(string: "1.01")!).rounded(scale: 2)
                    $0.fees = 25
                }
            }
            make(.buy, date) {
                $0.instrumentID = demo.instrument.id
                $0.listingID = demo.listing.id
                $0.quantity = purchase.quantity
                $0.price = unitPrice
                $0.currency = currency
                $0.fees = currency == .czk ? 49 : 2
                $0.fxRateToBase = currency == baseCurrency ? nil : fxToBase(currency, date)
            }
        }
        // Splits of Demo Chips (as a broker would book them).
        let chips = universe[5]
        for split in chips.splits where split.effectiveDate > start.adding(days: 30) && split.effectiveDate < today {
            make(.split, split.effectiveDate) {
                $0.instrumentID = chips.instrument.id
                $0.currency = chips.listing.tradingCurrency
                $0.splitNumerator = split.ratioNumerator
                $0.splitDenominator = split.ratioDenominator
            }
        }
        // Annual dividends from Demo Energie with 15 % withholding, and bond coupons.
        var year = start.year + 1
        while let date = LocalDate(year: year, month: 6, day: 15), date < today {
            make(.dividend, date) {
                $0.instrumentID = universe[0].instrument.id
                $0.amount = 80 * 38
                $0.taxWithheld = (80 * 38 * Decimal(string: "0.15")!).rounded(scale: 2)
                $0.currency = .czk
            }
            if let bond = universe[10].bond, let coupon = LocalDate(year: year, month: 11, day: 11), coupon < today {
                make(.coupon, coupon) {
                    $0.instrumentID = universe[10].instrument.id
                    $0.amount = 3 * bond.faceValue * bond.couponRate
                    $0.taxWithheld = (3 * bond.faceValue * bond.couponRate * Decimal(string: "0.15")!).rounded(scale: 2)
                    $0.currency = .czk
                }
            }
            year += 1
        }
        // A partial sale of the ETF two years ago.
        let saleDate = today.adding(years: -2).previousWeekday
        if saleDate > start.adding(days: 12), let price = rawClose(universe[7], saleDate) {
            make(.sell, saleDate) {
                $0.instrumentID = universe[7].instrument.id
                $0.listingID = universe[7].listing.id
                $0.quantity = 200
                $0.price = price
                $0.currency = .eur
                $0.fees = 2
                $0.fxRateToBase = fxToBase(.eur, saleDate)
            }
        }
        make(.fee, start.adding(months: 6)) { $0.amount = 120; $0.notes = "Custody fee (demo)" }
        return result
    }
}

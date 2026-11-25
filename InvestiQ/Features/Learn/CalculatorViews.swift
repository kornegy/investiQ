import Charts
import SwiftUI
import InvestiQCore
import InvestiQContent
import InvestiQPresentation

/// Interactive calculators in lessons. Inputs are illustrations chosen by the user, not expectations.
struct CalculatorView: View {
    @Bindable var model: LearnViewModel
    let kind: LessonCalculator

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: LocalizedStringKey("learn.calc.\(kind.rawValue).title"), help: "learn.calc.help")
                switch kind {
                case .compoundInterest: compound
                case .inflation: inflation
                case .feeDrag: fees
                case .currency: currency
                case .diversification: diversification
                }
            }
        }
    }

    private var compound: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            slider("learn.calc.initial", value: $model.compoundInitial, range: 0...100_000, step: 1_000, format: .number)
            slider("learn.calc.monthly", value: $model.compoundMonthly, range: 0...5_000, step: 100, format: .number)
            slider("learn.calc.rate", value: $model.compoundRate, range: 0...0.10, step: 0.005, format: .percent)
            Stepper(value: $model.compoundYears, in: 1...40) { Text(L10n.string(Message("learn.calc.years", [.integer(model.compoundYears)]))) }
            Chart(model.compoundPoints) { point in
                AreaMark(x: .value("year", point.year), y: .value("value", point.nominalValue.doubleValue))
                    .foregroundStyle(by: .value("series", L10n.string("learn.calc.withGrowth")))
                LineMark(x: .value("year", point.year), y: .value("value", point.contributed.doubleValue))
                    .foregroundStyle(by: .value("series", L10n.string("learn.calc.paidIn")))
            }
            .frame(height: 200)
        }
    }

    private var inflation: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            slider("learn.calc.amount", value: $model.inflationAmount, range: 1_000...1_000_000, step: 1_000, format: .number)
            slider("learn.calc.inflation", value: $model.inflationRate, range: 0...0.10, step: 0.005, format: .percent)
            Stepper(value: $model.inflationYears, in: 1...40) { Text(L10n.string(Message("learn.calc.years", [.integer(model.inflationYears)]))) }
            Chart(model.inflationPoints) { point in
                LineMark(x: .value("year", point.year), y: .value("value", point.value))
                    .foregroundStyle(by: .value("series", L10n.string("learn.calc.purchasingPower")))
            }
            .frame(height: 180)
            if let last = model.inflationPoints.last {
                Text(L10n.string(Message("learn.calc.inflation.result", [.integer(last.year), .decimal(Decimal(finite: last.value) ?? 0, fractionDigits: 0)])))
            }
        }
    }

    private var fees: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            slider("learn.calc.amount", value: $model.feeAmount, range: 1_000...1_000_000, step: 1_000, format: .number)
            slider("learn.calc.grossReturn", value: $model.feeGross, range: 0...0.10, step: 0.005, format: .percent)
            slider("learn.calc.fee", value: $model.feeRate, range: 0...0.03, step: 0.001, format: .percent)
            Stepper(value: $model.feeYears, in: 1...40) { Text(L10n.string(Message("learn.calc.years", [.integer(model.feeYears)]))) }
            Chart(model.feePoints) { point in
                LineMark(x: .value("year", point.year), y: .value("value", point.comparison))
                    .foregroundStyle(by: .value("series", L10n.string("learn.calc.withoutFee")))
                LineMark(x: .value("year", point.year), y: .value("value", point.value))
                    .foregroundStyle(by: .value("series", L10n.string("learn.calc.withFee")))
            }
            .frame(height: 200)
            if let last = model.feePoints.last {
                Text(L10n.string(Message("learn.calc.fee.result", [.decimal(Decimal(finite: last.comparison - last.value) ?? 0, fractionDigits: 0)])))
            }
        }
    }

    private var currency: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            slider("learn.calc.assetReturn", value: $model.currencyAssetReturn, range: -0.5...0.5, step: 0.01, format: .percent)
            slider("learn.calc.currencyChange", value: $model.currencyChange, range: -0.3...0.3, step: 0.01, format: .percent)
            Text(L10n.string(Message("learn.calc.currency.result", [.percent(model.currencyResult, fractionDigits: 1)]))).font(.title3)
        }
    }

    private var diversification: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            slider("learn.calc.singleVolatility", value: $model.diversificationVolatility, range: 0.1...0.6, step: 0.01, format: .percent)
            slider("learn.calc.correlation", value: $model.diversificationCorrelation, range: 0...1, step: 0.05, format: .number)
            Chart(model.diversificationPoints) { point in
                LineMark(x: .value("holdings", point.holdings), y: .value("volatility", point.volatility))
            }
            .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent()) }
            .frame(height: 180)
            Text("learn.calc.diversification.note").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum ValueFormat { case number, percent }

    private func slider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: ValueFormat) -> some View {
        HStack {
            Text(key).frame(width: 220, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(Text(key))
            Text(format == .percent ? Formatters.percent(value.wrappedValue, fractionDigits: 1)
                                    : Formatters.decimal(Decimal(finite: value.wrappedValue), fractionDigits: 2))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
    }
}

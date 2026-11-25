# InvestiQ — Financial Methodology

Status: v1. Every formula here is implemented in `InvestiQAnalytics` / `InvestiQServices` and covered
by tests with hand-checked values (`docs/TESTING_STRATEGY.md`). Each analytical result in the app shows
the method ID (e.g. `M-VOL-1`) so the user can find the definition here.

## 0. Numeric policy

* **Accounting** (quantities, prices, amounts, fees, cost basis, P&L, cash): `Decimal` (38 significant
  digits). Rounding only for display, using the currency's minor units (CZK/EUR/USD: 2) with
  banker's rounding disabled (`.plain`, half away from zero). Internal values are not rounded.
* **Statistics** (returns, volatility, correlation, Monte Carlo, YTM solving): `Double`, converted at a
  single boundary (`Decimal → Double`) and never converted back into accounting records.
* Missing data is `nil`, never `0`. Every result reports `completeness = available inputs / required inputs`.

## 1. Portfolio accounting (`PortfolioLedger`)

Transactions are replayed in order of `(trade_date, sequence)` where `sequence` orders same-day events:
splits → deposits/FX → buys → sells → income → fees/taxes → withdrawals. All amounts are in the
transaction currency; base-currency amounts use `fx_rate_to_base` (base units per 1 transaction-currency
unit) provided by the user/CSV or looked up from ECB/CNB for the trade date (the source is stored).

**Average cost method (M-ACC-1).** For each instrument position:

* Buy `q` at price `p`, fees `f`: `qty += q`; `cost += q·p + f` (fees are capitalised into cost basis);
  `costBase += (q·p + f)·fx`.
* Sell `q` at price `p`, fees `f` (partial or full): `avg = cost/qty`;
  `realised = q·p − f − q·avg` (instrument currency);
  `realisedBase = (q·p − f)·fx_sale − q·(costBase/qty)` (includes FX effect);
  `cost −= q·avg`; `costBase −= q·costBase/qty`; `qty −= q`.
  Selling more than held is rejected (`LedgerError.insufficientQuantity`) — no short positions in v1.
* Split `n:d` (e.g. 4:1): `qty = qty·n/d`; cost basis unchanged ⇒ average cost scales by `d/n`.
  Reverse splits use `n < d`. Fractional remainders paid as cash are recorded by the user as a sell.
* Bond redemption: treated as a sale of the full remaining quantity at the redemption price (default
  100% of face value).

**Cash (M-ACC-2).** Per-currency balances: deposit `+a`, withdrawal `−a`, buy `−(q·p+f)`, sell
`+(q·p−f)`, dividend/coupon/interest `+(gross − tax_withheld)`, fee `−a`, tax `−a`, FX conversion
`−a` in source currency and `+counter_amount` in target currency (the implied rate is stored; the
conversion fee is a separate fee field). Negative cash is allowed but flagged ("record your deposits").

**Income and costs.** Dividend income = Σ gross dividends (tax shown separately). Coupon income = Σ
gross coupons. Fees = Σ explicit fees (trade fees + standalone fees + FX conversion fees).

**Contributions vs. profit (M-ACC-3).** `netContributions = Σ deposits − Σ withdrawals` (base). For
portfolios that do not record deposits, external flows are inferred as the cash needed for purchases
(`netInvested = Σ buy costs − Σ sale proceeds − income received`, documented in UI). Deposits are never
counted as profit.

**Valuation (M-VAL-1).** `marketValue = Σ qty·price·fx_now + Σ cash·fx_now`.
`unrealised = Σ (qty·price·fx_now − costBase)`; this is split into **price effect**
`(price − avgCost)·qty·fx_now` and **FX effect** `costBase_ccy·fx_now − costBase` for transparency.
`totalReturn = realised + unrealised + income − taxes − standaloneFees`;
`totalReturn% = totalReturn / netContributions` when contributions > 0, else `nil`.

**Bond prices (M-VAL-2).** Bond quotes follow the market convention: clean price in percent of face
value (e.g. 101.20). The ledger records the price of **one bond** in the trading currency, so a bond
position is valued at `qty · quote/100 · face` and its price history is scaled by `face/100` before
valuation. The transaction editor accepts percent-of-face prices for bonds and converts them
(`unit = percent/100 · face`). Market value is a clean value; accrued interest is shown on the asset page
and recorded on purchase/sale transactions, not added to the market value.

**Historical valuation.** For each date `t`, holdings are derived from transactions with
`trade_date ≤ t`. If prices are split-adjusted, quantities before a split are converted to the post-split
basis (multiplied by the cumulative ratio of later splits) so value is continuous. Dates without a price
use the last available close (carried forward up to 5 trading days, then the point is marked missing).

## 2. Returns

* Simple return `r_t = P_t / P_{t−1} − 1`; log return `ln(P_t/P_{t−1})`.
* **Time-weighted return (M-RET-TWR).** Daily linking with external flows `F_t` assumed at the **start**
  of day `t`: `r_t = V_t / (V_{t−1} + F_t) − 1`, `TWR = Π(1 + r_t) − 1`. Annualised:
  `(1+TWR)^(365/days) − 1` only when the period ≥ 365 days (shorter periods are not annualised).
* **Money-weighted return / XIRR (M-RET-XIRR).** Solve `Σ CF_i / (1+r)^((d_i − d_0)/365) = 0`; flows
  from the investor's perspective (contributions negative, withdrawals and terminal value positive).
  Newton–Raphson from 10% with fallback to bisection on [−0.9999, 10]; converges when |NPV| < 1e-9·scale.
  Returns `nil` if no sign change exists.
* CAGR `(P_end/P_start)^(365.25/days) − 1`.

## 3. Risk statistics

* **Volatility (M-VOL-1):** sample standard deviation of daily log returns × √252 (trading days).
  Requires ≥ 60 returns, otherwise `insufficientData`.
* **Maximum drawdown (M-DD-1):** `max_t (1 − P_t / max_{s≤t} P_s)` with peak, trough and recovery dates.
* **Historical VaR/CVaR (M-VAR-1):** empirical quantile of 1-day (or h-day, non-overlapping) portfolio
  returns at 95%; CVaR = mean of returns ≤ VaR. Always labelled: "In the past period, losses larger than
  this occurred on about 5% of days. It is **not** the maximum possible loss."
* **Correlation (M-COR-1):** Pearson on aligned daily log returns (inner join on dates), ≥ 60 overlaps.
* **Beta (M-BETA-1):** `cov(r_i, r_m)/var(r_m)` vs. a user-selected benchmark.
* **Concentration (M-CON-1):** weights `w_i`; HHI = Σ w_i²; effective number of positions = 1/HHI.
  Flags: single position > 20%, single issuer > 25%, sector > 40%, country > 60% (excluding broad
  ETFs where look-through data is unavailable — reported as a limitation), currency ≠ base > 50%.
* **Liquidity (M-LIQ-1):** days to liquidate = position value / (20% × average daily traded value over
  20 days). > 5 days → elevated liquidity risk. Missing volume → `unknown`.

**Portfolio risk report (M-RISK-1, method version `risk-1`).** Inputs: current holdings valued in the
base currency, one year of daily local-currency log returns per holding, portfolio return series
`r_t = Σ w_i·r_{i,t}` at **current** weights (historical simulation; FX moves are not included — stated
as a limitation). Exposures by issuer, sector, country, currency (ETF look-through when known; cash is
labelled `cash:<base>`) and asset type. Each category gets a level `low < moderate < elevated < high`
(or `unknown`) from the metric and thresholds `(a, b, c)`: `< a` low, `< b` moderate, `< c` elevated,
otherwise high.

| Category | Metric | Thresholds |
|---|---|---|
| Market | annualised portfolio volatility | 8 % / 15 % / 25 % |
| Credit | share in individual bonds below investment grade or unrated (no bonds → low) | 0 % / 10 % / 30 % |
| Liquidity | share needing > 5 days to sell at 20 % of ADV; individual bonds count as less liquid | 10 % / 30 % / 60 % |
| Currency | share in currencies ≠ base (look-through) | 10 % / 40 % / 70 % |
| Inflation | share in bonds, bond ETFs and cash | 20 % / 50 % / 80 % |
| Concentration | top issuer weight / HHI | > 10 % moderate; > 20 % or HHI > 0.15 elevated; > 40 % or HHI > 0.25 high |
| Interest rate | value-weighted modified duration (bond ETFs: assumed 7 years, labelled) | 1 / 3 / 6 |
| Political (qualitative) | share outside developed markets | 10 % / 30 % / 60 % |
| Regulatory (qualitative) | any non-UCITS fund → moderate | — |
| Counterparty (qualitative) | synthetic ETFs or cash > 50 % → moderate | — |

Each assessment is stored (`risk_assessments`, levels only) so changes over time can be shown later.

## 4. Fundamentals & valuation (stocks)

| ID | Metric | Formula | Notes |
|---|---|---|---|
| M-FUN-1 | Revenue growth | `Rev_t / Rev_{t−1} − 1` (annual, same fiscal basis) | needs two periods |
| M-FUN-2 | Operating margin | `OperatingIncome / Revenue` | |
| M-FUN-3 | Net margin | `NetIncome / Revenue` | |
| M-FUN-4 | Free cash flow | `CFO − CapEx` | CapEx sign normalised |
| M-FUN-5 | Debt-to-equity | `TotalDebt / TotalEquity` | negative equity → not meaningful (flagged) |
| M-VAL-2 | P/E | `Price / EPS(TTM)` | EPS ≤ 0 → "not meaningful", never a negative P/E |
| M-VAL-3 | P/B | `Price / BookValuePerShare` | |
| M-VAL-4 | Dividend yield | `Σ dividends last 12m / Price` | |
| M-VAL-5 | Market cap | `Price × SharesOutstanding` or provider value (source shown) | |

Sector comparison uses provider sector medians only when a source exists; otherwise "no comparison".

## 5. Bonds (M-BND)

* Coupon schedule generated backwards from maturity in steps of `12/f` months (end-of-month rule
  preserved). Zero-coupon bonds (`f = 0`) have a single redemption flow.
* **Day count conventions:** `30/360` (US bond basis), `30E/360`, `ACT/360`, `ACT/365F`, `ACT/ACT ICMA`.
* **Accrued interest (M-BND-AI):** `AI = C/f × DCF(lastCoupon, settlement)/DCF(lastCoupon, nextCoupon)`
  for ACT/ACT ICMA; `C × DCF(lastCoupon, settlement)` for other conventions (C = annual coupon per face).
* Dirty price = clean price + AI (both per 100 face).
* **Yield to maturity (M-BND-YTM):** street convention: solve `Dirty = Σ CF_k / (1+y/f)^(f·t_k)` with
  `t_k` in years from settlement using the bond's day count; Newton with bisection fallback on
  [−0.99, 1.0]. Current yield = annual coupon / clean price.
* **Macaulay duration** `D = Σ t_k·PV_k / Σ PV_k`; **modified** `D/(1+y/f)`; **convexity** standard
  discrete formula. Price change estimate `ΔP/P ≈ −D_mod·Δy + ½·Conv·Δy²`; stress tests use full
  repricing.
* Yield to call / worst when a call schedule exists.
* Hold-to-maturity explanation: cash flows are fixed (if the issuer does not default); interim price
  moves matter only if sold before maturity; reinvestment rate affects realised yield.

## 6. ETFs (M-ETF)

TER cost drag: `value_T = V0·((1+g)·(1−TER))^T` versus without TER. Tracking difference =
ETF total return − index total return over the same period (needs both series; otherwise "unknown").
Tracking error = stdev of daily return differences × √252. Currency exposure comes from geography/
holdings currency allocation (look-through), **not** from the trading currency.

## 7. Stress tests (hypothetical, M-STR)

| Scenario | Model |
|---|---|
| Equity market decline `−x%` | Stocks/equity ETFs: `ΔV = −x·β_i` (β from history, default 1.0 with "assumed" label) |
| Interest rates `+Δy` | Bonds: full reprice at `y+Δy`; equities: no direct effect modelled (stated) |
| Inflation `π` for `T` years | Real value of cash/fixed income: `V/(1+π)^T`; equities not modelled (stated) |
| Base currency appreciation `z%` | `ΔV = −Σ V_foreign·z` (ETF currency look-through when known) |
| Credit spread widening `+s` | Corporate bonds (all or one issuer): full reprice at `y+s` |
| Issuer default | Bonds of the issuer: `−V·(1−R)` with recovery R = 40 %; shares of the issuer: `−V` |
| Single company decline `−x%` | Applied to that issuer's direct holdings |

Presets in the app: equities −20 % and −40 %; rates +1, +2 and −1 pp; inflation 5 % for 3 years; base
currency +10 %; corporate spreads +2 pp; default of the largest issuer; largest issuer −50 %. Bond ETFs
in the rate scenario use the assumed 7-year duration (marked "assumed"). All results are labelled
"Hypothetical scenario — not a forecast" and list their assumptions; no probability is attached.

## 8. Forecasting & validation (M-FC)

**Models**

| ID | Model | Output |
|---|---|---|
| FC-NAIVE | Random walk: `P̂_{t+h} = P_t` | baseline |
| FC-DRIFT | Random walk with drift estimated from training window log returns | point + interval |
| FC-BOOT | Block bootstrap of historical log returns (block 20 days), 2 000 paths, seeded | quantile bands |

A GBM Monte Carlo model (normal returns) was considered and left out of v1: with μ and σ from the same
window it produces nearly the same bands as FC-DRIFT while understating fat tails; the bootstrap keeps the
empirical tails.

**Scenarios (optimistic / base / pessimistic):** built from the empirical distribution of **historical
rolling h-period returns** of the instrument (price only; at least `max(3h, 756)` observations, otherwise
the app says history is insufficient — no proxy is substituted): pessimistic =
20th percentile, base = median, optimistic = 80th percentile. They are presented as "outcomes observed in
past periods of the same length", with no probability attached to each scenario. Assumptions, horizon,
range, risks and limitations are listed for each.

**Sensitivity analysis:** outcome grid for a user-chosen illustration amount over constant annual
returns around the historical median (±2/±4 pp) × horizons 1, 5 and 10 years.

**Validation (walk-forward, expanding window):** origins every 21 trading days after a minimum 252-day
training window; for each origin the model sees only data with date ≤ origin (`TimeSeries.asOf(origin)`
enforces this). Metrics on the evaluation set:

* MAE, RMSE (in price units and in log-return units)
* **MASE** = MAE_model / MAE_naive(in-sample, h-step) — < 1 means better than naive
* **Relative MAE** = MAE_model / MAE of the naive forecast made at the same origins (out of sample;
  exactly 1 for the naive model). This is the direct "did it beat the baseline" test.
* Directional accuracy (excluding |actual move| < 0.1%)
* Interval coverage at 80% and 95% (target 0.80/0.95) and calibration curve (coverage at 10…90%)

**Usefulness gate:** a model is shown as a "signal" only if MASE < 0.95 **and** relative MAE < 0.95
**and** 80% coverage within
[0.70, 0.90] on ≥ 30 evaluations; otherwise the UI states "This model did not outperform a naive
baseline — do not use it as an investment signal". Point forecasts for prices are never presented
without the interval.

**Bias controls:** look-ahead (enforced by type + test that mutating future data never changes past
forecasts), survivorship (universe-based backtests flag that delisted instruments are absent from free
data), corporate actions (adjusted series required; unadjusted series rejected for return statistics),
costs (simulator and strategy backtests deduct fees and FX spreads).

**Forecast ledger:** every forecast the user records is stored before the target date, append-only
(database triggers reject updates and deletes), with model version, input hash (SHA-256 of the closes
used), data source, the model's validation MASE and the stale-input flag. The target date is `h`
weekdays after the last observation. A forecast is evaluated once, when a close on or before the target
date (carried forward ≤ 5 days) exists: absolute error, the naive forecast's error, 80/95 % interval hits
and direction (dead band 0.1 %). The Forecast record lists every forecast — successes and failures — and
per-model average error next to the naive error for the same forecasts.

**Stale data:** forecasts are refused when the last observation is more than 7 calendar days (≈ 5
trading days) old or the series is served stale from cache, unless the user explicitly confirms a
warning; the forecast is then marked `staleInput`.

## 9. Analytical statuses (rules)

| Status | Triggered when (any) |
|---|---|
| `insufficientData` | completeness < 50% of required inputs, or < 60 daily returns |
| `elevatedRisk` | volatility > 35% p.a., or max drawdown (5y) > 50%, or D/E > 2.0, or bond rating below investment grade / unrated |
| `elevatedUncertainty` | conflicting sources, stale data, forecast interval width (80%) > 60% of price, or negative earnings |
| `metricsWarrantReview` | negative FCF two years in a row, operating margin decline > 5 pp YoY, dividend payout > 100% of EPS |
| `furtherResearchRequired` | always shown as the default status when no other rule fires |

The thresholds are heuristics for **education**, not investment advice; they are listed in the UI.

## 10. Financial planning (M-PLAN)

* Free cash flow = income − essential − additional − debt payments.
* Income/expense ratio = income / (essential + additional + debt payments).
* Emergency-fund coverage = emergency fund / (essential expenses + debt payments) (months).
* Income loss: months until savings are exhausted with income reduced by x%.
* Unexpected expense: months of free cash flow needed to rebuild the fund after a shock of amount A.
* Savings scenario: `FV = PV(1+i)^n + PMT·((1+i)^n − 1)/i` monthly, nominal and inflation-adjusted.
* Safety checks (educational, not advice): emergency fund < 3 months, free cash flow ≤ 0, high-interest
  debt present → the planner explains why such money is usually not invested, and never suggests an
  investment amount.

## 11. Simulator (M-SIM)

**Sessions.** A session is a virtual portfolio (database triggers reject real portfolios) with a starting
deposit. *Live* mode uses the current (delayed) quote and dates trades today. *Historical* mode starts
≥ 30 days in the past; prices are the last close on or before the simulated date (carried ≤ 7 days),
exchange rates are those of that date, and the simulated date can only move forward (never past today).

**Order pricing.** Fill = reference × (1 ± spread/2) (buy +, sell −), rounded to 4 decimals. Bond
references are converted from percent of face to the price of one bond. Value = qty × fill.
Commission (base currency) = max(minimum, fixed + percent × value_base). Foreign instruments: cash is
converted automatically each way with an FX fee = fxFee × value (an `fxConversion` transaction before a
buy, after a sale). Defaults: 0.1 % commission (min. 1), 0.1 % spread, 0.25 % FX fee — all editable.
Orders that need more base cash than available, or sell more than held, are rejected (no leverage, no
shorting). Example (tested): 10 × 100 USD at 25 CZK/USD → fill 100.05, value 25 012.50 CZK, commission
25.01, FX fee 62.53, total 25 100.04 CZK.

**Benchmark.** Each deposit/withdrawal buys/sells benchmark units at that day's close with the same fee
model (quantity scaled once so the cash moved after costs ≈ the flow); value on the simulated date.

**Mistake analysis (observations, not judgements).** Annual turnover = min(buys, sells) / average value /
years > 100 %; trades per month > 8 (both only with ≥ 5 trades); costs > 1 % of starting capital per
year; a position > 20 %; sales when the close was ≥ 10 % below its 90-day high ("selling after a fall",
using only data up to the sale); cash > 50 % after the first month.

**Strategy lab (back-test).** Fixed target weights (sum 100 %), initial amount on the first trading day
and a monthly contribution on the first trading day of each later month, invested at target weights.
Rebalancing: never, annually (anniversary month), quarterly, or when any weight drifts > 5 pp (checked
monthly). Each trade costs commission + spread/2 (+ FX fee for foreign assets). Prices and monthly FX
rates are looked up as of each date (look-ahead test: changing later data never changes earlier
results). Outputs: value and contributions series, TWR (daily returns net of the day's contribution),
annualised volatility, maximum drawdown, costs, number of rebalancings; benchmark = the same
contributions into one instrument, never rebalanced. Double precision (statistics); results never enter
a ledger.

## 12. News classification (M-NEWS)

* **Categories (M-NEWS-1):** the 13 categories of spec §16 by keyword lists (English and Czech) matched
  at word starts in the headline and summary (a trailing space in a keyword requires a whole word, so
  "war" does not match "warning"). An item can have several categories or none.
* **Statement type:** items from official feeds are `officialRelease` (uncertainty low). Otherwise the
  first matching cue decides: rumour cues ("reportedly", "people familiar", "údajně"…) → `rumour`;
  opinion cues ("opinion", "column", "komentář"…) → `opinion`; forecast cues ("expect", "outlook",
  "prognóz"…) → `forecast` (all three: uncertainty high); else `reported` (medium). The matching cue is
  shown with the item.
* **Deduplication (M-NEWS-2):** same canonical URL (https, lower-case host without `www.`, no query or
  fragment, no trailing slash), or within 48 hours headlines with word-set Jaccard ≥ 0.6, or containment
  ≥ 0.85 with ≥ 5 shared words. The earliest item is kept and the other outlets are listed.
* **Related instruments:** provider symbols, or the instrument name without legal suffixes (≥ 4
  characters) as whole words. Related sectors come from matched instruments and from the categories.
* **Possible effects:** fixed, reviewed texts per category describing channels (rates → borrowing costs,
  valuations, existing bond prices…), always followed by the caveat that the actual reaction depends on
  expectations and other circumstances. No direction is ever predicted and no score is computed.


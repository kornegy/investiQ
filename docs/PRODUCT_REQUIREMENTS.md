# InvestiQ — Product Requirements

Status: Draft v1 (Phase 0). Source of truth for scope: `InvestiQ_English_Prompt.md` (project specification).
This document translates the specification into testable product requirements and records what is
explicitly **out of scope**.

## 1. Vision

InvestiQ is a local-first macOS assistant that helps beginner investors **understand** stocks, bonds and
ETFs, track their own investments honestly, and learn to reason about risk. It is an educational and
analytical tool. It never executes trades, never promises returns and never issues personalised
BUY/SELL recommendations.

Priority order for every trade-off (from the specification):

1. User safety
2. Reliability of financial information
3. Accuracy of financial calculations
4. Transparency of analytics
5. Honest representation of forecast uncertainty
6. Data privacy
7. Ease of use
8. Architectural extensibility
9. Performance
10. Visual design

## 2. Target users

| Persona | Description | Key needs |
|---|---|---|
| Beginner (primary) | Has savings, never invested, lives in Czechia/EU, Russian- or Czech-speaking | Plain-language explanations, safety checks (emergency fund, debt), simulator, learning path |
| Intermediate | Holds a few ETFs/stocks at an EU broker | Portfolio accounting across CZK/EUR/USD, dividends, fees, risk overview |
| Advanced | Understands instruments, wants transparent analytics | Fundamentals, bond math, scenario/stress testing, forecast validation |
| Minor (under 18) | Learner | Education + virtual portfolios only; no broker sign-up links, no real-transaction guidance |

Knowledge level is captured separately from risk capacity (ability to absorb losses) and risk attitude.
None of them alone determines anything about "acceptable" risk.

## 3. Scope and functional requirements

Requirement IDs are referenced from tests and from `docs/TESTING_STRATEGY.md`.

### 3.1 Profiles, authentication, security (FR-AUTH)

- FR-AUTH-1 Create a local profile protected by a password (min 10 characters, strength feedback).
- FR-AUTH-2 Unlock with password; optional Touch ID through the system (LocalAuthentication + Keychain access control).
- FR-AUTH-3 Automatic lock after configurable inactivity (1/5/15/30 min), on system sleep and on screen lock; manual lock (⌘L).
- FR-AUTH-4 Persistent rate limiting of failed unlock attempts (exponential lockout).
- FR-AUTH-5 Change password (requires current password; re-wraps the data key, no data re-encryption).
- FR-AUTH-6 Delete a profile and all associated data (crypto-shredding: keys removed from Keychain, files removed).
- FR-AUTH-7 Encrypted backup to a user-chosen file with a separate backup passphrase; verified restore.
- FR-AUTH-8 No plaintext password storage, no custom cryptography, no collection of biometric data.

### 3.2 Onboarding (FR-ONB)

Collects only what the app needs: country of residence, primary currency (CZK/EUR/USD), age category,
knowledge level, goals, horizon, income stability, essential monthly expenses, emergency-fund status,
debt obligations, risk attitude, previous experience. Never asks for ID documents, bank credentials,
payment details or account access. Age category "under 18" enables **Educational mode** permanently for
that profile (virtual portfolios only).

### 3.3 Overview / Dashboard (FR-DASH)

Total value, invested amount, realised and unrealised P&L, return %, dividends, coupons, fees, cash,
allocation, value over time (1D, 3D, 1W, 1M, 3M, 1Y, All), important events, risk warnings and data
freshness. When history is missing the chart shows an explicit "no historical data" state — never a
fabricated curve.

### 3.4 Market Explorer (FR-MKT)

Search by name/ticker/ISIN; filter by type (stock, ETF, government bond, corporate bond), country,
sector, currency; sort by metrics; watchlist; side-by-side comparison. An instrument is identified by an
internal ID plus ISIN/FIGI; each **listing** (exchange MIC + ticker + trading currency) is separate. Every
displayed value shows source, retrieval time, market timestamp and delay status.

### 3.5 Instrument analysis (FR-STK, FR-BND, FR-ETF)

- Stocks: fundamentals and valuation metrics when reliably available (market cap, revenue and growth,
  net income, EPS, P/E, P/B, FCF, D/E, operating margin, dividend yield and history, volatility, max
  drawdown, earnings, sector performance). Investment-thesis worksheet with arguments for **and** against,
  missing data and invalidation conditions. Only neutral analytical statuses (see §5).
- Bonds: separate model (face value, coupon, frequency, maturity, YTM, current yield, duration, rating,
  clean/dirty price, accrued interest, denomination, liquidity, callability) plus explanations of the
  seven bond risks and hold-to-maturity vs. secondary-market sale.
- ETFs: manager, index, TER, AUM, holdings, geography/sector allocation, replication, tracking difference
  and error, accumulating/distributing, UCITS, trading currency vs. currency exposure, KID availability.

### 3.6 Analytics, risk, forecasting (FR-ANL, FR-RISK, FR-FCST)

- Every analytical result carries: inputs, sources, formula/method, calculation date, limitations,
  completeness, and a plain-language explanation. Missing inputs are reported as missing (never 0).
- Risk module: ten risk categories, exposures by company/sector/country/currency/asset type/issuer,
  correlations, concentration, hypothetical stress tests. VaR is never presented as maximum loss.
- Forecasting: statistical baselines, Monte Carlo where justified, scenario ranges (optimistic/base/
  pessimistic) with assumptions, sensitivity analysis, walk-forward validation against naive baselines,
  a permanent forecast ledger and a Forecast Accuracy page that shows failures too. A model that does not
  beat the naive baseline is labelled "not a useful signal".

### 3.7 Portfolio (FR-PF)

Multiple real and virtual portfolios (kept strictly separate), manual entry and CSV import of buys,
sells, dividends, coupons, fees, taxes, deposits, withdrawals, splits, FX conversions and bond
redemptions. Derived metrics: average cost, cost basis, market value, realised/unrealised P&L, total
return, dividend and coupon income, fees, TWR and XIRR. Decimal arithmetic for all money.

### 3.8 News and calendar (FR-NEWS)

Aggregation from configured providers and official RSS feeds; deduplication; categories (13);
classification into confirmed fact / opinion / rumour / forecast; uncertainty level; hedged
cause-and-effect explanations; always with source, dates and link; never full article reproduction.
Economic calendar with time zones and rescheduling.

### 3.9 Planner, simulator, brokers, education, notifications (FR-PLAN, FR-SIM, FR-BRK, FR-EDU, FR-NTF)

- Planner: free cash flow, income/expense ratio, emergency-fund months, income-loss and shock scenarios,
  savings and portfolio scenarios for amounts the user chooses. Safety-first messaging.
- Simulator: virtual capital, simulated trades with fees, FX and data delay; historical mode without
  look-ahead; benchmark comparison; allocation strategy tests; mistake analysis. No leaderboards,
  streaks or rewards for trading frequency.
- Broker directory: only verified fields with verification date and official register link; no
  referral links or paid ranking; minors see no sign-up links.
- Education: 21 mandatory topics, learning path, calculators, quizzes, virtual examples.
- Notifications: local, informative, never manipulative; no claim of 24/7 monitoring.

### 3.10 AI (FR-AI) — optional

AIProvider abstraction (none / Ollama / Apple Foundation Models / external API). Off by default, explicit
consent, data minimisation, prompt-injection defences, structured-output validation, no tool access
(cannot trade, run commands or modify records). Core features work without any model.

### 3.11 Demo mode (FR-DEMO)

Runs without API keys using clearly labelled synthetic data in a separate, non-persistent store. Demo
and real data never mix.

## 4. Non-functional requirements

| ID | Requirement | Verification |
|---|---|---|
| NFR-1 | Native macOS app (SwiftUI), Apple Silicon optimised, light/dark | macOS CI build, manual QA |
| NFR-2 | Local-first: all user data stored locally, encrypted at rest | Security tests, code review |
| NFR-3 | No mandatory backend; network only for public market/news data | Architecture review |
| NFR-4 | Main thread never blocked by I/O or heavy computation | Instruments (Time Profiler) — to be measured on device |
| NFR-5 | No continuous high-frequency polling; refresh limits; Low Power Mode aware | Code review, tests of refresh policy |
| NFR-6 | Offline: portfolio, history, transactions entry, calculators, education, cached data, simulations | Offline tests |
| NFR-7 | Accessibility: VoiceOver labels, keyboard navigation, no colour-only information | Accessibility audit checklist |
| NFR-8 | Localisation: Russian (primary), English, Czech; String Catalogs; CZK/EUR/USD | l10n completeness script |
| NFR-9 | No hidden telemetry, no analytics SDKs | Dependency audit |

## 5. Analytical statuses (no BUY/SELL)

`furtherResearchRequired`, `insufficientData`, `elevatedUncertainty`, `elevatedRisk`,
`metricsWarrantReview`. They are derived by documented, deterministic rules
(`docs/FINANCIAL_METHODOLOGY.md` §9) and always shown together with the rule that triggered them.

## 6. Explicitly out of scope (v1)

Cryptocurrencies, leverage, margin, CFDs, binary options, derivatives; order execution or broker account
connections; personalised investment recommendations; server backend or cloud sync; user leaderboards;
storage of banking credentials.

## 7. Acceptance (Definition of Done)

See specification §36. Tracking of each criterion lives in `docs/reports/TESTING_REPORT.md` and
`docs/ROADMAP.md`. Production-ready status requires independent security, legal and data-licensing
review — this project does **not** claim it.

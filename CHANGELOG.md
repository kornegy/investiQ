# Changelog

All notable changes to this project are documented here. Format: Keep a Changelog; versions follow
SemVer once releases start.

## [Unreleased]

### Phase 7 — Production preparation (in progress)
- Encrypted backups (`.iqbackup`: authenticated header with Argon2id parameters, AES-256-GCM payload,
  separate passphrase, API keys never included); restore validates integrity and foreign keys, migrates
  older backups, refuses newer ones, keeps the previous encrypted generation, and only then switches.
  Crafted KDF parameters are refused.
- JSON export of all user-entered data (clearly marked as unencrypted); clearing of the market-data cache.

### Phase 6 — Optional AI
- `AIProvider` with Apple on-device (macOS 26+), local Ollama (loopback only) and Claude Messages API
  adapters; AI off by default; the app is fully functional without it.
- Explicit consent for external AI, blocked for minors and demo; fixed task list without personal
  financial data; portfolio risk levels only with explicit permission; secret scanning before sending.
- Prompt-injection defences (untrusted-data wrapping, delimiter stripping, detection flags), strict
  schema validation, rejection of advice and invented probabilities, removal of invented links, flags
  for figures not in the input; no tools, answers never stored.
- "Explain with AI" in lessons, news and risk categories; learning question box; Settings → AI.
- Transport: POST support with body hashing in dedup/log keys; plain HTTP only to loopback.

### Phase 5 — News and education (in progress)
- Financial planner: budget (blank fields stay unknown), free cash flow, income/expense ratio, emergency
  fund coverage, income-loss and unexpected-expense what-ifs, savings scenario (nominal and in today's
  money), hypothetical portfolio moves in months of costs, goals; educational notes that never propose an
  amount to invest.
- Simulator: live and historical sessions (forward-only simulated date, no later data), realistic order
  costs (commission, spread, automatic FX conversion with fee), cash and quantity checks, benchmark with
  the same deposits, mistake analysis; strategy lab with fixed weights, contributions, rebalancing rules
  and costs. No rankings, streaks or rewards.
- Fix: cached price history counted as a hit when it covered only the start of a request (could hide
  recent prices); fetched bars are now merged into the cache instead of replacing it.
- Portfolio snapshots can be valued as of a past date (used by historical simulations).
- Education: all 21 mandatory topics as lessons in ru/en/cs (summary, sections, analogy, key points,
  quiz with explanations) on a four-stage learning path; five interactive calculators (compound
  interest, inflation, fees, currency, diversification); progress stored encrypted; finishing the course
  is explicitly not presented as readiness to invest. Lessons are generated from `Content/lessons`, so the
  languages cannot drift apart (checked in CI).
- News: official press releases (ECB, Fed, ČNB RSS) and Finnhub news; explainable classification into 13
  categories and five statement types with uncertainty; deduplication; related instruments and sectors;
  cautious cause-and-effect notes; only headlines and short summaries are kept; demo news.
- Economic calendar: central-bank decisions and statistics releases verified against official pages with
  source links, time zones, tentative/rescheduled status; earnings dates for library instruments.
- Broker directory: six firms relevant for Czechia/EU with only verified facts (legal entity, supervisor,
  licence type, presence in Czechia, investor-compensation scheme and limits where documented, deposit
  insurance shown separately), sources and verification date; unverified facts shown as "not verified";
  alphabetical, no ranking or referral links; broker websites hidden in educational mode.
- Notifications: nine rule types (price moves above a user threshold, earnings, economic events,
  dividends, coupons, bond maturity, risk-level changes, outdated data, provider problems) with lead
  times; factual wording; delivered through macOS notifications only while InvestiQ runs, only after the
  user allows them; each fact is notified once (delivery log, schema v2).

### Phase 4 — Analytics and risk
- Bond analytics (schedules, five day counts, accrued interest, YTM/YTC, durations, convexity, full
  repricing), ETF analysis (cost drag, currency look-through, KID expectation), neutral rule-based
  statuses and an investment thesis worksheet for stocks.
- Statistical forecasting (naive, drift, block bootstrap) with walk-forward validation against a naive
  baseline (MAE, RMSE, MASE, relative MAE, direction, 80/95 % coverage, calibration) and a usefulness
  gate; historical scenario ranges without probabilities; sensitivity grid.
- Append-only forecast ledger with later evaluation and a public forecast record; stale input refused
  unless explicitly confirmed and then flagged.
- Portfolio risk: ten categories with published thresholds, exposures, correlations, historical VaR/CVaR
  (never described as maximum loss), hypothetical stress tests with listed assumptions.
- Risk section and asset analysis cards in the app.
- Fix: bond positions were valued from percent-of-face quotes as if they were per-bond prices; quotes are
  now converted (`qty · quote/100 · face`), and the transaction editor accepts percent-of-face prices.

### Phase 3 — Portfolio accounting
- Ledger (average cost per instrument and currency, partial sales, oversell rejection, capitalised and
  base-currency fees, dividends/coupons with withholding tax, accrued interest, splits, bond redemption,
  multi-currency cash, FX conversions, missing FX → unknown instead of zero).
- Valuation with price/FX effect split, explicit return basis, historical value series (split-aware),
  time-weighted return and XIRR (spreadsheet reference verified).
- Portfolio service with ledger re-validation on add/update/delete, ledger hash, sampled performance series.
- CSV import (preview, per-row errors, `;`/decimal comma, dd.mm.yyyy, idempotent re-import, atomic) and
  export with formula-injection protection.
- Dashboard (all spec §8 metrics, 7 ranges, allocation, rule-based notes, freshness) and Portfolio UI.

### Phase 2 — Market data
- Provider layer (rate limits, retries, dedup, validation, conflict detection, encrypted cache, stale-on-outage).
- Adapters: Alpha Vantage, Finnhub, Twelve Data, FMP, Massive, ECB, CNB, FRED, SEC EDGAR; demo provider.
- Market Explorer, watchlist, comparison, asset details with charts and explainable statistics, provider settings.

### Phase 1 — Foundation
- Encrypted local profiles (Argon2id + AES-GCM + Keychain), Touch ID, auto-lock, onboarding, settings,
  Xcode project, CI (Linux + macOS build + UI tests).

### Phase 0 — Research and architecture
- Environment analysis (Linux dev container, Swift 6.2 via Docker, macOS CI on GitHub `macos-26`).
- Product requirements, architecture, database schema, security design, threat model, data-provider
  research, financial methodology, UI/UX, testing strategy, roadmap, legal notes, ADRs.
- Legal drafts: privacy policy, terms of use, financial risk, data sources and forecast methodology disclosures.
- Reproducible Linux build image (`ci/Dockerfile.linux`) with libsodium 1.0.22 built from the upstream tag.

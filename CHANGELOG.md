# Changelog

All notable changes to this project are documented here. Format: Keep a Changelog; versions follow
SemVer once releases start.

## [Unreleased]

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

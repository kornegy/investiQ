# InvestiQ — Testing report

Date: 2026-11-25 · Commit: see `git log -1` on branch `claude/upbeat-cori-u977ll`.

## Summary

| Suite | Where | Result |
|---|---|---|
| Package tests (`InvestiQKit`, XCTest) | Linux, Docker `swift:6.2-noble` (`./scripts/test-linux.sh`) | **244 passed, 0 failed** |
| Package tests incl. Keychain adapter | macOS 26 runner, GitHub Actions (`swift test`) | passed (last verified run: #14) |
| App build (`xcodebuild build`, Xcode 26) | macOS 26 runner | passed (run #14) |
| UI tests (`InvestiQUITests`: demo navigation through all sections; create profile → lock → unlock) | macOS 26 runner | passed (run #14) |
| Localisation completeness (1 259 keys × ru/en/cs, placeholder parity, `%` escaping) | CI lint job | passed |
| Copy lint (manipulative/promissory phrases incl. lessons) | CI lint job | passed |
| Lessons generated from source (structure identical in 3 languages) | CI lint job | passed |

Runs #15–#18 (Phase 6/7 commits) were in progress when this report was written; check
https://github.com/kornegy/investiQ/actions for their final state.

## Coverage by area (package tests)

| Area | Main suites | What is verified |
|---|---|---|
| Core | `LocalDateTests`, `MoneyAndDecimalTests`, `IdentifierTests`, `TransactionValidatorTests` | Civil-date arithmetic, Decimal parsing/rounding, ISIN Luhn, transaction validation |
| Security | `CryptoTests`, `AuthHardeningTests`, `LinkSafetyTests` | Argon2id known-answer vector, AES-GCM tamper detection, key envelope, login throttling incl. clock rollback, IDN/homograph link checks |
| Persistence | `SQLiteAndSchemaTests`, `EncryptedStoreTests` | Migrations (idempotent, refuses newer DB, **v1→v2 upgrade keeps data**), constraints/triggers (append-only forecasts, virtual-only simulator), encrypted file format, atomic write + previous generation |
| Data providers | `GatewayTests`, `ProviderContractTests` (32 fixtures) | Rate limits, retries with backoff, dedup, status mapping, sentinel values → missing, each adapter's parsing |
| Market data | `MarketDataServiceTests` | Freshness, fallback, stale-on-outage, conflicts, **history cache coverage + merge (regression)** |
| Portfolio | `PortfolioLedgerTests` (16), `PortfolioValuationTests`, `PortfolioServiceTests` | Average cost, partial sales, fees, dividends/coupons with tax, splits, FX, missing FX → unknown, TWR, XIRR (spreadsheet reference), CSV round trip, **bond percent-of-face valuation (regression)** |
| Analytics | `PerformanceTests`, `ReturnsTests`, `BondMathTests`, `ForecastValidationTests`, `RiskAndAnalysisTests`, `FinancialPlannerTests`, `SimulatorEngineTests`, `LearningCalculatorsTests`, `NotificationEvaluatorTests` | Hand-checked values for every formula in `FINANCIAL_METHODOLOGY.md`; look-ahead tests (forecast validation, back-test); usefulness gate never true for the naive model |
| Services | `AnalysisServicesTests`, `SimulatorServiceTests`, `NewsAndCalendarTests`, `BackupTests`, `AISecurityTests` | Forecast ledger immutability and evaluation, risk assessment recording, historical simulator never sees later data, news classification/dedup, calendar time zones, backup tamper detection and restore safety, AI security (see below) |
| Presentation | `AppFlowTests`, `MarketViewModelTests`, `PortfolioViewModelTests`, `AnalysisViewModelTests` (+ planner, simulator, learn, news, notifications, AI settings) | End-to-end flows on the demo session and real profiles: onboarding, minors → educational mode, auto-lock, broker websites hidden for minors, notifications sent once, AI off by default |
| Content | `LessonCatalogTests`, `DirectoryAndCalendarContentTests` | 21 mandatory lessons in 3 languages with identical answers; broker data sourced, alphabetical, no referral parameters; calendar entries sourced with valid time zones |
| Performance | `PerformanceBenchmarks` | Ceilings for heavy operations (see PERFORMANCE_REPORT.md) |

## AI security tests (Phase 6)

Prompt injection in news (forged delimiters stripped, instructions flagged), advice and probability
output rejected, schema enforced (extra keys, empty answers, non-JSON), invented links removed, figures
not in the input flagged, consent required, external AI blocked for minors, disabled state, stored keys
never sent, portfolio context minimised for external providers, request shape (no tools, no sampling
parameters, JSON-schema output), refusal and truncation handling, loopback-only local transport.

## Defects found by tests during development (all fixed)

* Bond positions valued from percent-of-face quotes as if they were per-bond prices (Phase 4).
* Cached price history treated as a hit when it covered only the start of a request; short fetches
  replaced longer cached history (Phase 5).
* Forecast usefulness gate relied only on in-sample MASE (added out-of-sample relative MAE).
* Notification calendar horizon ignored the configured lead time.
* Several `try?` on user-data paths that hid failures (ledger hash, value series, CSV export,
  performance chart, editor loading, file import, settings saves) — now surfaced (Phase 7 audit).
* macOS-only compile issues caught by CI: SwiftUI `Transaction` name clash, slow type-check in day
  counts, ambiguous percent axis format.

## Not covered by automated tests (manual testing required on a Mac)

* VoiceOver walkthrough of every screen, keyboard-only navigation, high-contrast and reduced-motion
  settings (see ACCESSIBILITY_REPORT.md).
* Touch ID enrolment change, Data Protection Keychain with a signed build.
* Live provider calls with real API keys (contract tests use recorded/documented formats because the
  development container blocks provider hosts).
* Apple Foundation Models adapter on macOS 26 hardware; Ollama with a real local model.
* Local notification delivery and permission prompts.
* Long-running memory profiling with Instruments.

## How to run

```bash
./scripts/test-linux.sh                     # all package tests in Docker
cd InvestiQKit && swift test                # on macOS
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -destination 'platform=macOS' test
python3 scripts/check_l10n.py && python3 scripts/lint_copy.py && python3 -B scripts/build_lessons.py
```

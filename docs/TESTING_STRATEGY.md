# InvestiQ — Testing Strategy

## 1. Layers

| Category | Where | Runs on | Notes |
|---|---|---|---|
| Unit | `InvestiQKit/Tests/*` | Linux (Docker, Swift 6.2) + macOS CI | XCTest; deterministic (`FixedClock`, seeded RNG) |
| Financial calculation | `InvestiQAnalyticsTests`, `InvestiQServicesTests/Portfolio*` | both | Hand-computed expected values documented in test comments |
| Integration | `InvestiQServicesTests`, `InvestiQPresentationTests` | both | Real SQLite + encrypted file + services + view models with mock providers |
| Database migration | `InvestiQPersistenceTests/Migration*` | both | Fixture DB at version N → migrate → assert data |
| Security | `InvestiQSecurityTests` | both | KDF vectors, envelope tamper, wrong password, rate limiting, CSV injection, link safety, redaction, encrypted-file tamper |
| API contract | `InvestiQDataTests/*Contract*` | both | Fixture JSON/CSV per endpoint incl. error, rate-limit, empty, malformed and sentinel cases |
| Forecast validation | `InvestiQAnalyticsTests/Forecast*` | both | Look-ahead invariance, metric correctness, baseline gate |
| Offline mode | `InvestiQServicesTests/Offline*` | both | `OfflineHTTPClient` → cached data served with stale status, no data loss |
| Apple adapters | `InvestiQPlatformAppleTests` | macOS CI | Keychain round-trip (legacy keychain) |
| UI | `InvestiQUITests` | macOS CI | Launch → demo mode → navigate all sections; create profile → lock → unlock |
| Copy/l10n lint | `scripts/lint_copy.py`, `scripts/check_l10n.py` | CI | Banned phrases; every key translated into ru/en/cs |

## 2. Priority test matrix (spec §31)

| Area | Key cases |
|---|---|
| P&L | single buy/sell, multiple buys, partial sells, sell-all, fees on both legs, oversell rejected |
| Fees | capitalised into cost, standalone fees, FX conversion fee |
| Dividends/coupons | gross vs withholding tax, cash impact, income totals |
| Splits | 4:1, 1:10 reverse, split between buys and sells, historical valuation continuity with adjusted prices |
| Currency | buy in USD with base CZK, FX gain with zero price change, conversion transaction |
| XIRR | known Excel examples, all-positive flows → nil, irregular dates |
| TWR | flows at period start, zero flows equals simple return, independence from flow size |
| Bonds | accrued interest per day count, YTM at par = coupon, price–yield inverse, duration of zero = maturity |
| Risk | HHI, concentration flags, VaR sign/labels, stress test arithmetic |
| Invalid API responses | malformed JSON, HTML error page, 429, 403 premium, all-zero quote, "None" strings, NaN, future timestamps |
| Missing/outdated data | nil not zero, stale labels, forecast refusal on stale input |
| Authentication | create/unlock/wrong password/lockout/password change/delete |
| Encryption | round trip, tamper detection (header and body), wrong key |
| Backup | create → restore round trip, wrong passphrase, corrupted file, newer schema refusal |

## 3. Rules

* No test touches the network. Providers are tested with `MockHTTPClient` and fixtures.
* Deterministic data: fixed dates, fixed seeds; no `Date()` inside logic (inject `Clock`).
* Coverage is reported (`swift test --enable-code-coverage`) but quality beats percentage.

## 4. Commands

```bash
# Linux (Docker) — package tests
./scripts/test-linux.sh
# macOS — package tests
cd InvestiQKit && swift test
# macOS — app build + UI tests
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -destination 'platform=macOS' test
```

# InvestiQ

A local-first macOS assistant for learning to invest: market exploration, honest portfolio accounting,
transparent analytics, risk and scenario analysis, financial planning, a paper-trading simulator and a
structured course — for stocks, bonds and ETFs. No crypto, leverage or derivatives. No trade execution.
No personalised buy/sell recommendations.

> **Status:** under active development (see `docs/ROADMAP.md`). Not production-ready: security, legal
> and data-licensing reviews are pending (`docs/LEGAL_COMPLIANCE.md`).

## Highlights

* **Private by design** — all data stays on your Mac, encrypted (AES-256-GCM, Argon2id, Keychain,
  optional Touch ID). No servers, no telemetry.
* **Honest data** — every value shows its source, time and delay; missing data is shown as missing.
* **Correct maths** — Decimal accounting, average cost, partial sales, fees, dividends, coupons,
  splits, multi-currency, TWR and XIRR, bond YTM/duration — all tested.
* **Transparent analytics** — every result links to its formula in
  [`docs/FINANCIAL_METHODOLOGY.md`](docs/FINANCIAL_METHODOLOGY.md).
* **Honest forecasting** — scenario ranges and validated statistical models; a public accuracy record.
* **Demo mode** — explore everything without API keys using clearly labelled synthetic data.
* Russian, English and Czech.

## Requirements

| | |
|---|---|
| Run | macOS 14 Sonoma or later, Apple Silicon recommended |
| Build | Xcode 26 or later (Swift 6.2+) |
| Package tests without a Mac | Docker (see below) |

## Build and run

```bash
git clone <repo-url> investiQ && cd investiQ
open InvestiQ.xcodeproj          # select scheme "InvestiQ" → Run (⌘R)
```

Command line:

```bash
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -configuration Debug -destination 'platform=macOS' build
```

The project uses a placeholder bundle identifier `com.example.InvestiQ` and "Sign to Run Locally".
For Touch ID unlock (Data Protection Keychain) set your own Development Team and bundle identifier in
the target's *Signing & Capabilities*.

## Tests

```bash
cd InvestiQKit && swift test                       # package tests (macOS)
./scripts/test-linux.sh                            # package tests in Docker (Linux, Swift 6.2)
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -destination 'platform=macOS' test
```

## Configuring data providers

InvestiQ works offline and in demo mode without keys. For live data open **Settings → Data
Providers**, enter your own free or paid API keys (stored only in the macOS Keychain) and enable
providers. ECB and Czech National Bank exchange rates need no key. See
[`docs/DATA_PROVIDERS.md`](docs/DATA_PROVIDERS.md) for limits, delays and licensing.

## Backups

**Settings → Backup & Restore → Create backup…** writes an encrypted `.iqbackup` file protected by a
backup passphrase you choose (it cannot be recovered). Restore verifies integrity before replacing data;
the previous data is kept until the restore succeeds.

## Documentation

| Document | Content |
|---|---|
| [Product requirements](docs/PRODUCT_REQUIREMENTS.md) | Scope, requirements, out of scope |
| [Architecture](docs/ARCHITECTURE.md) · [Decisions](docs/DECISIONS.md) | Modules, data flow, ADRs |
| [Database schema](docs/DATABASE_SCHEMA.md) | Tables, constraints, migrations |
| [Security](docs/SECURITY.md) · [Threat model](docs/THREAT_MODEL.md) | Crypto, keys, threats |
| [Data providers](docs/DATA_PROVIDERS.md) | API research and limits |
| [Financial methodology](docs/FINANCIAL_METHODOLOGY.md) | Every formula |
| [UI/UX](docs/UI_UX.md) · [Testing](docs/TESTING_STRATEGY.md) · [Roadmap](docs/ROADMAP.md) | |
| [Legal notes](docs/LEGAL_COMPLIANCE.md) · [legal drafts](docs/legal/) | Regulatory analysis, drafts |
| [Reports](docs/reports/) | Testing, security, performance, limitations, App Store checklist |

## Disclaimer

InvestiQ provides general information and education. It is not investment advice. Investing involves
risk, including loss of capital. Past performance does not guarantee future results.

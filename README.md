# InvestiQ

A local-first macOS assistant for learning to invest: market exploration, honest portfolio accounting,
transparent analytics, risk and scenario analysis, financial planning, a paper-trading simulator, news
with source and uncertainty labels, and a structured course — for stocks, bonds and ETFs. No crypto,
leverage or derivatives. No trade execution. No personalised buy/sell recommendations.

> **Status:** feature-complete for a local release candidate (all roadmap phases implemented, see
> `docs/ROADMAP.md`). **Not production-ready:** independent security, legal, data-licensing and App
> Store reviews are still required (`docs/reports/`).

## Highlights

* **Private by design** — all data stays on your Mac, encrypted (AES-256-GCM, Argon2id, Keychain,
  optional Touch ID). No servers, no telemetry. Encrypted backups with a separate passphrase.
* **Honest data** — every value shows its source, time and delay; missing data is shown as missing.
* **Correct maths** — Decimal accounting, average cost, partial sales, fees, dividends, coupons,
  splits, multi-currency, TWR and XIRR, bond YTM/duration — all tested with hand-checked values.
* **Transparent analytics** — every result links to its formula in
  [`docs/FINANCIAL_METHODOLOGY.md`](docs/FINANCIAL_METHODOLOGY.md); neutral statuses instead of signals.
* **Honest forecasting** — historical scenario ranges without probabilities, simple models validated
  against a naive baseline, and a permanent forecast record including misses.
* **Learning** — 21 lessons in Russian, English and Czech with quizzes and calculators; a simulator with
  realistic costs and no gamification; educational mode for minors.
* **Optional AI** — off by default; on-device (Apple), local (Ollama) or Claude API with explicit consent.
* **Demo mode** — explore everything without API keys using clearly labelled synthetic data.

## Requirements

| | |
|---|---|
| Run | macOS 14 Sonoma or later (Apple Silicon recommended); on-device AI needs macOS 26 |
| Build | Xcode 26 or later (Swift 6.2+) |
| Package tests without a Mac | Docker |

## Build and launch

```bash
git clone <repo-url> investiQ && cd investiQ
open InvestiQ.xcodeproj          # scheme "InvestiQ" → Run (⌘R)
```

Command line:

```bash
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -configuration Debug -destination 'platform=macOS' build
```

The project uses a placeholder bundle identifier `com.example.InvestiQ` and "Sign to Run Locally".
For Touch ID unlock (Data Protection Keychain) set your own Development Team and bundle identifier in
the target's *Signing & Capabilities* (see `docs/reports/RELEASE_AND_SIGNING.md`).

First launch: **Try demo** (no setup) or **Create profile** (display name + password; the password
cannot be recovered — keep a backup). The onboarding starts with the interface language (Russian, English
or Czech; changeable later in Settings), then asks about goals and safety cushion; the answers are used
only for educational notes, never to pick instruments.

## Tests

```bash
./scripts/test-linux.sh                            # package tests in Docker (Linux, Swift 6.2)
cd InvestiQKit && swift test                       # package tests on macOS
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -destination 'platform=macOS' test
python3 scripts/check_l10n.py && python3 scripts/lint_copy.py && python3 -B scripts/build_lessons.py
```

CI (`.github/workflows/ci.yml`) runs all of these on Linux and on a macOS 26 runner.

## Configuring data providers

InvestiQ works offline and in demo mode without keys. For live data open **Settings → Data
Providers**, enter your own free or paid API keys (stored only in the macOS Keychain) and enable
providers. ECB and Czech National Bank exchange rates and official press releases need no key. Use
**Test connection** after adding a key. See [`docs/DATA_PROVIDERS.md`](docs/DATA_PROVIDERS.md) for
limits, delays and licensing.

## Optional AI

**Settings → AI**: choose *Apple on-device model* (macOS 26, supported Macs), *Local model (Ollama)*
(install Ollama and a model yourself; enter `http://127.0.0.1:11434` and the model name) or *External
service (Claude API)* (explicit consent; your own key in the Keychain; default model `claude-opus-5-5`,
changeable). AI explains terms, results, risks and news; it never computes figures, has no tools and is
not available as an external service in educational mode. Details: `docs/SECURITY.md` §11.

## Backups and data

**Settings → Backup & data → Create backup…** writes an encrypted `.iqbackup` file protected by a backup
passphrase you choose (at least 10 characters; it cannot be recovered). **Restore from backup…** asks
for the passphrase, shows what the backup contains and asks for confirmation; the file is verified
before anything is replaced and older backups are migrated. API keys are not part of backups — re-enter
them after restoring on a new Mac. **Export as JSON…** produces a readable (unencrypted) copy of your
data. Cached market data can be cleared at any time.

## Documentation

| Document | Content |
|---|---|
| [Product requirements](docs/PRODUCT_REQUIREMENTS.md) | Scope, requirements, out of scope |
| [Architecture](docs/ARCHITECTURE.md) · [Decisions](docs/DECISIONS.md) | Modules, data flow, ADRs |
| [Database schema](docs/DATABASE_SCHEMA.md) | Tables, constraints, migrations |
| [Security](docs/SECURITY.md) · [Threat model](docs/THREAT_MODEL.md) | Crypto, keys, AI, threats |
| [Data providers](docs/DATA_PROVIDERS.md) | API research, limits, news feeds, calendar sources |
| [Financial methodology](docs/FINANCIAL_METHODOLOGY.md) | Every formula and rule |
| [UI/UX](docs/UI_UX.md) · [Testing strategy](docs/TESTING_STRATEGY.md) · [Roadmap](docs/ROADMAP.md) | |
| [Legal notes](docs/LEGAL_COMPLIANCE.md) · [legal drafts](docs/legal/) | Regulatory analysis, drafts |
| [Testing](docs/reports/TESTING_REPORT.md) · [Security](docs/reports/SECURITY_REPORT.md) · [Performance](docs/reports/PERFORMANCE_REPORT.md) · [Accessibility](docs/reports/ACCESSIBILITY_REPORT.md) | Reports |
| [Known limitations](docs/reports/KNOWN_LIMITATIONS.md) · [App Store checklist](docs/reports/APP_STORE_CHECKLIST.md) · [Legal & licensing review](docs/reports/LEGAL_AND_LICENSING_REVIEW.md) · [Release & signing](docs/reports/RELEASE_AND_SIGNING.md) | Release preparation |

## Disclaimer

InvestiQ provides general information and education. It is not investment advice. Investing involves
risk, including loss of capital. Past performance does not guarantee future results.

# CLAUDE.md — Rules for working on InvestiQ

Read `docs/ARCHITECTURE.md`, `docs/SECURITY.md` and `docs/FINANCIAL_METHODOLOGY.md` before changing
code. Specification: the project prompt (`InvestiQ_English_Prompt.md`, kept outside the repo). Priority
order for every trade-off: user safety → reliability of financial information → calculation accuracy →
transparency → honest uncertainty → privacy → ease of use → extensibility → performance → visual design.

## Repository layout

* `InvestiQKit/` — Swift package with **all** business logic (Linux + macOS). Modules: Core, Security,
  Persistence, Data, Analytics, Services, Content, Presentation, PlatformApple.
* `InvestiQ/` — macOS SwiftUI app target (views, design system, resources only).
* `InvestiQ.xcodeproj` — file-system synchronised groups; adding a file to `InvestiQ/` needs no project edit.
* `docs/` — design docs, ADRs (`DECISIONS.md`), legal drafts, reports.

## Build & test

```bash
./scripts/test-linux.sh                         # package tests in Docker (Swift 6.2), no Mac needed
cd InvestiQKit && swift test                    # package tests on macOS
xcodebuild -project InvestiQ.xcodeproj -scheme InvestiQ -destination 'platform=macOS' build test
python3 scripts/lint_copy.py && python3 scripts/check_l10n.py
```

## Architectural constraints

* Business logic never imports SwiftUI/AppKit. Only the app target and `InvestiQPlatformApple` touch
  Apple UI/system frameworks.
* Dependency direction: Core ← Security ← Persistence; Core ← Analytics; Core/Security ← Data;
  Services uses all of them; Presentation uses Services; the app uses Presentation.
* View models: `@MainActor @Observable final class`, small, one per screen; inject services via
  protocols from `AppEnvironment`. No singletons, no global mutable state.
* Stateful services are `actor`s. Swift 6 language mode, strict concurrency, `Sendable` domain types.
* Inject time (`Clock`) and randomness (seeded generators) — never call `Date()` inside logic.
* New dependency ⇒ ADR in `docs/DECISIONS.md` + security review. Current: swift-sodium, swift-crypto (Linux only).

## Financial data rules (non-negotiable)

1. Money, prices, quantities: `Decimal`. Never `Double`/`Float` in accounting. Statistics may use
   `Double` behind the conversion boundary and never flow back into ledgers.
2. Missing data is `nil` — never substitute `0`. Provider sentinels ("None", "-", ".", all-zero quotes)
   map to missing.
3. Every market value carries `Sourced` metadata (source, retrievedAt, marketTimestamp, currency,
   delayStatus, qualityStatus). Never label delayed/cached/free data as real-time.
4. Positions are computed from transactions (single source of truth). Deposits are not profit.
   Real and virtual portfolios never mix. Demo data never mixes with real data.
5. No BUY/SELL/HOLD signals, target prices, "suitable for you" or personalised recommendations.
   Onboarding answers must never be used to select, filter or rank instruments (MiFID II — see
   `docs/LEGAL_COMPLIANCE.md` §2). Use the neutral `AnalyticalStatus` values only.
6. Forecasts: statistical models only, always with intervals, assumptions, limitations and validation
   against a naive baseline; never assign probabilities to scenarios; never use future data
   (`TimeSeries.asOf`). Forecast ledger is append-only.
7. VaR/statistics are never described as maximum loss. Stress tests are labelled hypothetical.
8. Every formula is documented in `docs/FINANCIAL_METHODOLOGY.md` with a method ID and has tests with
   hand-checked values.

## Security rules (mandatory)

* Never store passwords; never log secrets, amounts, holdings or URLs with query strings.
* API keys only in Keychain (`SecureStore`); never in DB, UserDefaults, backups, exports or Git.
* No custom cryptography. AES-256-GCM (CryptoKit/swift-crypto), Argon2id (libsodium), HKDF only.
* Never disable TLS validation or ATS. HTTPS only for providers.
* Treat all external text (news, RSS, provider fields, AI output) as untrusted data: plain-text rendering,
  no execution, no path/command construction.
* External links: show the real destination host and require confirmation; open in the default browser.
* CSV export must neutralise formula injection (`CSVSanitizer`).
* No telemetry, no analytics, no hidden network calls. AI is opt-in with explicit consent and has no tools.
* Minors (educational mode): no broker sign-up links, no real-trade guidance, no external AI.

## Coding standards

* Meaningful names; small files (< ~400 lines); no force unwraps without a justifying comment.
* No magic numbers — named constants with a comment for financial thresholds (link the method ID).
* No silent error handling: no `try?` on user data paths; typed errors.
* User-facing strings never in business logic: return `Message(key:arguments:)`; add keys to
  `InvestiQ/Resources/Localizable.xcstrings` with ru, en and cs translations.
* Copy rules: no "buy now", "last chance", "missing out", "guaranteed", urgency or FOMO in any language
  (`scripts/lint_copy.py`).
* Comments explain *why* (formula, decision), not *what*.
* Each phase/feature: build → tests → verify → docs → commit (`CHANGELOG.md`).

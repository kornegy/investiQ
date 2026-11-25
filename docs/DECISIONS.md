# InvestiQ — Architecture Decision Records

Format: context → decision → consequences. Newest at the bottom. Status: Accepted unless noted.

## ADR-001 Cross-platform core package + thin macOS app

**Context.** The development environment is Linux without Xcode; the product is a native macOS app
with a future iOS port; business logic must be UI-independent and heavily tested.
**Decision.** All business logic, persistence, networking, analytics and view models live in the
SwiftPM package `InvestiQKit`, compiled and tested on Linux (Docker, Swift 6.2) and macOS. The Xcode app
target contains only SwiftUI views, the design system and resources. Apple-only adapters live in the
package module `InvestiQPlatformApple`, compiled only where the frameworks exist.
**Consequences.** ~80% of the code is verified in this environment; the SwiftUI layer is verified by
macOS CI. iOS port reuses the package unchanged.

## ADR-002 SQLite with a small in-house wrapper instead of SwiftData

**Context.** Requirements: explicit migrations, referential integrity, unique constraints, indexes,
transactions, encryption control, Linux testability.
**Decision.** System SQLite through a ~400-line wrapper (no ORM). Schema in SQL migrations.
**Alternatives.** SwiftData (Apple-only, no Linux tests, no encryption, weaker migration testing);
GRDB (excellent, but an additional dependency and its SQLCipher variant needs a custom build).
**Consequences.** More SQL written by hand; full control and testability.

## ADR-003 Encryption at rest: encrypted serialised SQLite images

**Context.** The system SQLite has no encryption. Options: SQLCipher (extra native dependency, custom
build on Apple platforms), per-column encryption (leaks which instruments/dates exist and breaks
constraints on encrypted columns), whole-file encryption.
**Decision.** Each database runs in memory; after each committed write the image is serialised with
`sqlite3_serialize`, encrypted with AES-256-GCM (header as AAD) and atomically written. On open the file
is decrypted and loaded with `sqlite3_deserialize`.
**Consequences.** Everything including metadata is encrypted; constraints work normally; crash safety via
atomic rename plus one previous generation. Memory cost equals database size (user DB is small — a
10 000-transaction ledger is a few MB). Large datasets (price history) are compacted one-row-per-series.
If data volume grows substantially, migrate to SQLCipher (ROADMAP).

## ADR-004 Argon2id through swift-sodium (libsodium)

**Context.** The spec asks for Argon2id through a vetted library. CryptoKit has no password KDF.
**Decision.** swift-sodium 0.12.0 (exact pin) → libsodium `crypto_pwhash` Argon2id13, t=3, m=64 MiB.
Password verification is implicit in AES-GCM unwrapping of the key envelope (no stored hash).
**Alternatives.** PBKDF2 via CommonCrypto (not memory-hard), scrypt via swift-crypto `_CryptoExtras`
(underscored API).
**Consequences.** One dependency with a prebuilt xcframework on Apple platforms (maintained by the
libsodium author); Linux CI compiles libsodium 1.0.22 from the upstream tag.

## ADR-005 Decimal for money, Double for statistics

Money, quantities and prices use `Decimal`; statistics use `Double` behind one conversion boundary;
results of statistics never flow back into the ledger.

## ADR-006 Instrument identity

Internal UUID per instrument; ISIN (validated check digit) and FIGI as identifiers; listings are
(MIC, ticker, trading currency). A ticker alone is never a global key.

## ADR-007 Provider abstraction with capability registry and Sourced<T>

Protocols per data domain, adapters declare capabilities/limits, a gateway centralises rate limiting,
retries, dedup and caching; every value carries source/time/delay/quality metadata.

## ADR-008 Demo mode is a separate in-memory session

Demo uses `DemoDataProvider` (deterministic synthetic data, `delayStatus = .synthetic`) and an
in-memory database that is never written to disk. Real profiles cannot load the demo provider, so the
two never mix. The UI shows a permanent "Demo data" banner.

## ADR-009 Statistical forecasting only, with validation gate

No LLM forecasting. Baselines + GBM/bootstrap Monte Carlo + historical scenario ranges; walk-forward
validation with MASE and interval coverage decides whether a model may be described as useful.

## ADR-010 Optional AI with no capabilities

AI is behind `AIProvider`; default `.none`. The AI layer receives only explicit, minimised text,
returns schema-validated JSON, has no tools and no write access.

## ADR-011 Neutral analytical statuses

No BUY/SELL/HOLD, no target prices, no personalised suitability. Five neutral statuses derived by
published rules.

## ADR-012 Localisation through message descriptors

Business logic returns `Message(key, arguments)`; the app resolves keys via String Catalogs (ru/en/cs)
and formats typed arguments with the user's locale. Long-form lessons are per-language JSON.

## ADR-013 Xcode project with file-system synchronised groups + local package

The project file (objectVersion 77) references folders instead of individual files, minimising merge
conflicts and allowing the project to be authored without Xcode. CI (`macos-26`) builds and tests it.

## ADR-014 Swift 6 strict concurrency

Swift 6 language mode; view models on MainActor; stateful services as actors; Sendable domain types.

## ADR-015 Deployment target macOS 14

Observation framework (`@Observable`) requires macOS 14. Apple Foundation Models features are gated
with `#available(macOS 26, *)`. Building requires Xcode 26+.

## ADR-016 Positions are a projection of transactions

No mutable positions table. `PortfolioLedger` replays transactions; valuation snapshots store the ledger
hash so cached values are verifiable and automatically invalidated.

# InvestiQ — Architecture

Status: v1 (Phase 0, updated as phases complete). Decisions are justified in `docs/DECISIONS.md` (ADR-xxx).

## 1. Environment analysis (Phase 0)

| Item | Finding | Consequence |
|---|---|---|
| Development container | Linux (Ubuntu 24.04), no macOS, no Xcode | The macOS app layer cannot be compiled in this container |
| Swift | Swift 6.2.4 (official `swift:6.2-noble` image via Docker); 6.4.3 also available | All platform-independent code builds and is tested on Linux with Swift 6.2 |
| macOS CI | GitHub-hosted `macos-26` runners (Apple Silicon, Xcode 26.x, Swift ≥ 6.2) | The Xcode project, SwiftUI layer and Apple-only adapters are verified by CI |
| User machine | Apple M1 Pro (spec). Exact macOS/Xcode version unknown (no Mac attached to this session) | Minimum deployment target **macOS 14.0**; building requires **Xcode 26+** |
| Network (dev container) | Market-data hosts are blocked by the sandbox policy | Provider contract tests use fixtures built from official documentation (see `DATA_PROVIDERS.md`) |

Because the authoring environment cannot run Xcode, the architecture deliberately pushes as much code as
possible into a **cross-platform Swift package** that compiles and is unit-tested on Linux and macOS.
The macOS app target is a thin SwiftUI shell plus Apple-specific adapters (ADR-001).

## 2. High-level structure

```text
investiQ/
├── InvestiQKit/                       Swift package (Linux + macOS), all business logic
│   ├── Sources/
│   │   ├── InvestiQCore/              Domain model, Money/Decimal, identifiers, Sourced<T>, Clock, errors, messages
│   │   ├── InvestiQSecurity/          AES-GCM, Argon2id KDF, key envelopes, SecureStore, rate limiter,
│   │   │                              link safety, CSV-injection sanitiser, log redaction
│   │   ├── InvestiQPersistence/       SQLite wrapper, migrations, encrypted database files, repositories,
│   │   │                              backup/restore, export, integrity checks
│   │   ├── InvestiQData/              HTTP client + request policies (rate limit, retry, dedup, timeout,
│   │   │                              cache), provider protocols, provider adapters, DTOs, mappers,
│   │   │                              validation, provider registry with fallback, demo provider
│   │   ├── InvestiQAnalytics/         Pure math: statistics, returns, drawdowns, fundamentals, bond math,
│   │   │                              ETF analysis, risk & stress tests, forecasting & validation, planning
│   │   ├── InvestiQServices/          Use cases: portfolio ledger & valuation, CSV import/export, market
│   │   │                              data service, news pipeline, calendar, simulator, notifications,
│   │   │                              education, brokers, AI orchestration, profile/session management
│   │   ├── InvestiQContent/           Bundled content (education lessons ru/en/cs, broker directory,
│   │   │                              scheduled events, cause-effect knowledge base)
│   │   ├── InvestiQPresentation/      @Observable view models (MainActor), AppEnvironment (DI container)
│   │   └── InvestiQPlatformApple/     Keychain, LocalAuthentication, UserNotifications, NWPathMonitor,
│   │                                  power state — compiled only where the Apple frameworks exist
│   └── Tests/                         XCTest suites per module (unit, integration, contract, security,
│                                      migration, forecast-validation, offline)
├── InvestiQ/                          macOS app target (SwiftUI views, design system, resources)
├── InvestiQUITests/                   UI tests (macOS CI)
├── InvestiQ.xcodeproj                 Xcode project (file-system synchronised groups + local package)
├── ci/Dockerfile.linux                Reproducible Linux test image
└── .github/workflows/ci.yml           Linux package tests + macOS build/test
```

### Dependency rules (enforced by SwiftPM target graph)

```text
Core  ←  Security  ←  Persistence
  ↑         ↑              ↑
  ├──── Analytics          │
  ├──── Data ──────────────┤
  └──── Services (Core, Security, Persistence, Data, Analytics, Content)
             ↑
        Presentation (Services + everything below; no SwiftUI)
             ↑
        App target (SwiftUI) + PlatformApple (adapters implementing protocols from Core/Security/Services)
```

* `InvestiQAnalytics` depends only on `InvestiQCore` — formulas have no I/O and are trivially testable.
* No module below the app target imports SwiftUI or AppKit. Business logic is UI-independent.
* View models depend on protocols (`PortfolioServicing`, `MarketDataServicing`, …) injected via
  `AppEnvironment`; tests inject fakes.

## 3. Runtime architecture

```text
┌────────────── SwiftUI Views (App target) ──────────────┐
│ Sidebar: Overview · Market · Portfolio · News · Risk ·  │
│ Planner · Simulator · Brokers · Learn · Settings        │
└───────────────▲────────────────────────────────────────┘
                │ @Observable state, intents
┌───────────────┴──────── Presentation (MainActor VMs) ───┐
│ AppModel (session state machine: noProfile → locked →    │
│ unlocked(session) / demo(session))                       │
└───────────────▲─────────────────────────────────────────┘
                │ async calls
┌───────────────┴──────────── Services (actors) ──────────┐
│ ProfileService · SessionManager · PortfolioService ·     │
│ MarketDataService · NewsService · RiskService ·          │
│ ForecastService · PlannerService · SimulatorService ·    │
│ NotificationService · AIService · BackupService          │
└──────▲───────────────▲─────────────────▲────────────────┘
       │               │                 │
 Persistence      Data (providers)    Analytics (pure)
 (EncryptedDB)    HTTPClient→URLSession
```

### 3.1 Session state machine

`AppModel.state`:

* `.loading` → `.welcome` (no profiles) | `.locked(profiles)`
* `.locked` → `.unlocked(UnlockedSession)` after password/Touch ID
* `.welcome` → `.demo(DemoSession)` ("Try demo") — synthetic, in-memory, never persisted
* any unlocked state → `.locked` on manual lock, inactivity timeout, sleep or screen lock

`UnlockedSession` owns the data-encryption key (in memory only), the opened databases and the
services bound to that profile. Locking releases the session; keys are released with it.

### 3.2 Concurrency

* Swift 6 language mode with strict concurrency checking everywhere.
* View models are `@MainActor @Observable`; they call services with `async` and keep `Task` handles
  so navigation away cancels in-flight work.
* Services that own mutable state are `actor`s. The SQLite connection is owned by a single actor
  (`DatabaseActor`) — all DB access is serialised off the main thread.
* Network requests go through `ProviderGateway` (actor) which applies per-provider token-bucket rate
  limiting, in-flight request de-duplication, retries with exponential backoff and jitter, timeouts and
  cancellation propagation.
* Heavy computations (Monte Carlo, walk-forward validation) run in detached tasks with cooperative
  cancellation checks.

### 3.3 Data flow for a market value

```text
Provider DTO ──map──▶ domain value ──validate──▶ Sourced<T>{value, source, retrievedAt,
marketTimestamp, currency, delayStatus, qualityStatus} ──▶ cache (encrypted) ──▶ VM ──▶ View badge
```

Conflicts between providers are detected by `ConflictDetector` (relative difference above a tolerance)
and surfaced as `DataQualityStatus.conflicting` with both values available to the UI.

### 3.4 Persistence

Two SQLite databases per profile (ADR-003):

| Database | Content | Durability |
|---|---|---|
| `user.iqdb` | Profile, preferences, financial profile, instruments referenced by the user, portfolios, transactions, watchlists, notification rules, forecasts & evaluations, risk snapshots, learning progress, planner data | Saved atomically after every committed write |
| `cache.iqdb` | Quotes, price history, statements, dividends, corporate actions, news, events, brokers, provider metadata | Debounced saves; fully regenerable |

Both run as in-memory SQLite databases that are serialised (`sqlite3_serialize`), encrypted with
AES-256-GCM and written atomically. See `docs/SECURITY.md` §3 and `docs/DATABASE_SCHEMA.md`.

### 3.5 Localisation

User-visible text never originates in business logic. Services return structured values and
`Message(key:arguments:)` descriptors; the app target resolves keys from `Localizable.xcstrings`
(ru, en, cs) and formats arguments with the current locale (ADR-012). Long-form content (lessons) is
structured JSON per language in `InvestiQContent`.

### 3.6 Platform adapters

Protocols live in the package; Apple implementations live in `InvestiQPlatformApple`:

| Protocol | Apple implementation |
|---|---|
| `SecureStore` | `KeychainSecureStore` (generic password items) |
| `BiometricKeyStore` | Data Protection Keychain item with `SecAccessControl(.biometryCurrentSet)` |
| `NotificationScheduling` | `UNUserNotificationCenter` |
| `NetworkStatusProviding` | `NWPathMonitor` |
| `PowerStateProviding` | `ProcessInfo.isLowPowerModeEnabled` |
| `ExternalLinkOpening` | `NSWorkspace.shared.open` after a confirmation dialog (app target) |

## 4. Modules in detail

### InvestiQCore
Money (`Decimal` + `CurrencyCode`), `Quantity`, `Percentage`, identifiers (`InstrumentID`, `ISIN` with
check-digit validation, `MIC`, `Ticker`, `ListingKey`), instrument and transaction domain types,
`Sourced<T>` and metadata enums, `Clock` protocol (deterministic tests), `Message` descriptors,
`AnalyticalStatus`, errors.

### InvestiQSecurity
`CryptoBox` (AES-256-GCM via CryptoKit on Apple, swift-crypto on Linux), `PasswordKDF` (Argon2id via
libsodium), `KeyEnvelope` (wrapped data-encryption key), `SecureStore`, `LoginThrottle`,
`PasswordPolicy`, `LinkSafety` (domain extraction, scheme allow-list, punycode/IDN warnings),
`CSVSanitizer`, `Redactor` (log redaction).

### InvestiQPersistence
Minimal SQLite wrapper (`Database`, `Statement`, typed binding), `Migrator` with ordered, tested
migrations, `EncryptedDatabaseFile` (serialize/deserialize + AES-GCM + atomic write),
repositories per aggregate, `BackupService` (portable encrypted backup with its own passphrase),
`DataExporter` (CSV/JSON), `IntegrityChecker`.

### InvestiQData
`HTTPClient` protocol (URLSession implementation + `MockHTTPClient`), `RequestPolicy`, `TokenBucket`,
`RetryPolicy`, `InFlightDeduplicator`, provider protocols (`MarketDataProvider`,
`FundamentalsProvider`, `NewsProvider`, `BondDataProvider`, `ETFDataProvider`,
`ExchangeRateProvider`, `MacroeconomicDataProvider`), adapters (Alpha Vantage, Finnhub, Twelve Data,
FMP, Massive, FRED, ECB, CNB, SEC EDGAR, RSS), `DemoDataProvider`, `ProviderRegistry`
(capability-based selection + fallback), `DataValidator`.

### InvestiQAnalytics
Statistics (mean, variance, quantiles, correlation), returns, volatility, drawdown, VaR/CVaR,
fundamentals & valuation, debt & liquidity analysis, bond math (schedule, accrued interest, YTM,
duration, convexity), ETF analysis, concentration (HHI), exposures, stress tests, forecasting models,
walk-forward validation and metrics (MAE, RMSE, MASE, directional accuracy, interval coverage,
calibration), planning calculations, XIRR/TWR solvers.

### InvestiQServices
`PortfolioLedger` (transaction replay → positions/cash/P&L), `ValuationService`,
`CSVTransactionImporter`, `MarketDataService`, `NewsPipeline` (fetch → normalise → dedupe → classify),
`EconomicCalendar`, `SimulatorEngine`, `NotificationRuleEvaluator`, `EducationCatalog`,
`BrokerDirectory`, `AIService`, `ProfileService`, `SessionManager`, `AppDataService`.

### InvestiQPresentation
View models per feature and `AppModel`. No SwiftUI imports; uses `Observation`. Fully unit-tested on
Linux.

## 5. Error handling

* Typed domain errors (`enum …Error: Error, Equatable`) — no silent `try?` on user data paths.
* Provider failures become `ProviderFailure` values with category (network, rateLimited, unauthorized,
  invalidResponse, notSupported, notFound) mapped to UI states (error, offline, stale data).
* API outages never delete cached or user data; stale cache is shown with an explicit stale badge.

## 6. Performance principles

Lazy loading and pagination for lists, single DB actor with prepared statements and indexes,
compact series storage (one row per price series), memoised derived values keyed by ledger hash,
refresh policy with minimum intervals (no high-frequency polling) and Low Power Mode back-off,
downsampling of long chart series before rendering. Claims about speed/memory will only be made after
measurement with Instruments (see `docs/reports/PERFORMANCE_REPORT.md`).

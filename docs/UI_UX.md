# InvestiQ — UI/UX Specification

References: Apple Human Interface Guidelines (macOS), usability research for financial apps. No other
product's interface is copied.

## 1. Principles

1. **Understandable for a first-time investor.** Plain words first, terms second (with a tooltip).
2. **Honest data.** Every number shows where it came from and how fresh it is.
3. **Calm.** No urgency, no confetti, no streaks, no red/green walls. Colour is a secondary cue.
4. **Safe defaults.** Educational mode for minors; safety checks before any "investment amount" talk.
5. **Native.** Sidebar navigation, toolbar, menus, keyboard shortcuts, system materials, Dark Mode.

## 2. Information architecture

`NavigationSplitView` with sidebar sections (⌘1…⌘0):

| # | Section | Content |
|---|---|---|
| 1 | Overview | Portfolio summary tiles, value chart with range picker (1D/3D/1W/1M/3M/1Y/All), allocation, risk warnings, upcoming events, data freshness |
| 2 | Market | Search (name/ticker/ISIN), filters, results table, watchlist, compare (up to 4) → Asset Details |
| 3 | Portfolio | Portfolio picker (real/virtual separated), holdings table, transactions, add/edit transaction sheet, CSV import/export |
| 4 | News | Category filter, statement-type badges, uncertainty, related assets, calendar tab |
| 5 | Risk Analysis | Risk categories, exposures, correlations, concentration, stress tests, Forecast Accuracy |
| 6 | Financial Planner | Budget form, ratios, emergency fund, shock scenarios, savings scenarios, goals |
| 7 | Simulator | Virtual portfolios, trade ticket, historical mode, benchmark, mistake analysis |
| 8 | Broker Directory | Filterable list, detail with verified fields and verification dates |
| 9 | Learn | Learning path, lessons, calculators, quizzes |
| 10 | Settings | Profile, security, data providers & API keys, AI, notifications, language/currency, backup/restore, data export/deletion, legal |

Asset Details (pushed from Market/Portfolio): header (name, ticker, ISIN, exchange, price + badges),
tabs: **Overview** (chart, key metrics), **Analysis** (stock/bond/ETF specific), **Thesis**
(for/against worksheet), **Scenarios** (forecast + validation), **Risks**, **Data & Sources**.

## 3. Wireframes (low fidelity)

```text
┌ Sidebar ─────────┬───────────────────────── Overview ─────────────────────────────┐
│ ◉ Overview       │ [DEMO DATA banner when in demo]           Data: delayed · 14:32  │
│ ○ Market         │ ┌Total value──┐┌Invested────┐┌Unrealised───┐┌Realised────┐    │
│ ○ Portfolio      │ │ 124 560 Kč  ││ 110 000 Kč ││ ▲ 12 310 Kč ││ ▲ 2 250 Kč │    │
│ ○ News           │ └─────────────┘└────────────┘└─────────────┘└────────────┘    │
│ ○ Risk Analysis  │ ┌ Value over time ────────── [1D 3D 1W 1M 3M 1Y All] ┐        │
│ ○ Planner        │ │  ╱╲__╱‾‾╲_╱‾‾‾                                       │        │
│ ○ Simulator      │ └──────────────────────────────────────────────────────┘        │
│ ○ Brokers        │ ┌ Allocation ┐ ┌ Risk notes ───────────┐ ┌ Upcoming ────────┐   │
│ ○ Learn          │ │ (donut)    │ │ ⚠ 46% in one company  │ │ ECB decision 3 d │   │
│ ─────────        │ └────────────┘ └───────────────────────┘ └──────────────────┘   │
│ ⚙ Settings       │ Sources: ECB (FX), Alpha Vantage (prices, delayed)               │
└──────────────────┴──────────────────────────────────────────────────────────────────┘
```

```text
┌ Lock screen ───────────────────────────┐
│            InvestiQ                    │
│  Profile: [Personal ▾]                 │
│  Password: [••••••••••]   [Unlock]     │
│  [ Unlock with Touch ID ]              │
│  "Too many attempts. Try again in 30 s"│
└────────────────────────────────────────┘
```

## 4. Design system (`InvestiQ/DesignSystem`)

| Token group | Values |
|---|---|
| Spacing | 4, 8, 12, 16, 24, 32 (`Spacing.xs…xxl`) |
| Corner radius | 6 (controls), 10 (cards) |
| Typography | System font (SF Pro) with Dynamic Type styles: `largeTitle` (screen titles), `title2` (card values), `headline`, `body`, `callout`, `caption` (metadata); monospaced digits for numbers |
| Colours | Semantic asset colours with light/dark variants: `Brand`, `Positive`, `Negative`, `Warning`, `Info`, `Neutral`; backgrounds use system materials |
| Gains/losses | Text + arrow glyph (▲/▼/–) + sign; colour only as reinforcement; colour-blind safe palette (blue/orange option in Settings) |
| Components | `Card`, `MetricTile`, `InfoTooltip`, `SourceBadge`, `FreshnessBadge`, `StatusBadge`, `EmptyStateView`, `ErrorStateView`, `OfflineBanner`, `DemoBanner`, `ExternalLinkButton`, `FormSection`, `CurrencyField`, `DataTable` (SwiftUI `Table`), chart wrappers (`LineChartCard`, `AllocationChart`, `RangeBandChart`) |

## 5. States

Every data view implements: **loading** (skeleton/ProgressView with label), **empty** (explanation +
primary action), **error** (plain-language cause + retry), **offline** (banner + cached data with age),
**stale** (badge), **partial** (missing fields listed), **demo** (persistent banner).

## 6. Copy rules

* No imperatives to trade ("buy", "sell now"), no urgency ("last chance"), no FOMO, no guarantees.
  Enforced by `scripts/lint_copy.py` for all languages.
* Forecasts: always "range", "scenario", "historical", never "will".
* Every analytical screen ends with "This is general information, not a personal recommendation."

## 7. Accessibility

VoiceOver labels and values on all controls and chart summaries (`accessibilityChartDescriptor`), full
keyboard navigation (default focus, ⌘-shortcuts, Tab order), Dynamic Type-friendly layouts, contrast ≥
4.5:1, reduced motion respected, no colour-only information.

## 8. Responsive layout

Minimum window 960×640. Tiles use adaptive grids (`LazyVGrid(.adaptive(minimum: 220))`); detail panes
collapse into tabs below 1100 pt width.

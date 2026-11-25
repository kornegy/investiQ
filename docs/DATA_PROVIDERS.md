# InvestiQ — Data Providers

Research date: 2026-11-24. Figures change often — **verify on the provider's official pricing/terms
page before relying on them**, and re-check before any commercial release. No provider is assumed to
deliver everything for free. No paid plan is purchased or activated by the app or by this project.

## 1. Abstraction

Unified protocols (in `InvestiQData`): `MarketDataProvider` (search, quotes, price history),
`FundamentalsProvider`, `NewsProvider`, `BondDataProvider`, `ETFDataProvider`,
`ExchangeRateProvider`, `MacroeconomicDataProvider`. Every adapter declares its **capabilities**
(which protocols, which regions/exchanges, delay class, history depth) and **limits** (requests per
minute/day). `ProviderRegistry` selects providers by capability and user priority, and falls back to
the next provider on `rateLimited`, `unavailable`, `notSupported` or `invalidResponse`.

Cross-cutting behaviour implemented once in `ProviderGateway`:

| Concern | Implementation |
|---|---|
| Rate limiting | Token bucket per provider (per-minute) + persisted daily counter |
| De-duplication | Identical in-flight requests share one `Task` |
| Retries | Exponential backoff with full jitter (base 0.5 s, max 3 attempts) only for idempotent GETs and transient errors (timeouts, 5xx, 429 with `Retry-After`) |
| Timeouts | 15 s request, 60 s resource |
| Cancellation | Structured concurrency; cancelled view → cancelled request |
| Caching | Encrypted cache DB with TTL per data type; stale data served with `stale` status during outages |
| Normalisation | DTO → domain mappers; "None", "-", "", `null`, `NaN`, and provider-specific zero sentinels mapped to **missing**, never 0 |
| Validation | `DataValidator` (see `SECURITY.md` §6) |
| Metadata | `Sourced<T>`: `source`, `retrievedAt`, `marketTimestamp`, `currency`, `delayStatus` (`realtime`, `delayed(minutes)`, `endOfDay`, `cached`, `stale`, `manual`, `synthetic`), `qualityStatus` (`validated`, `unvalidated`, `conflicting`, `partial`, `suspect`) |

A quote is labelled `realtime` **only** if the provider's documentation for the user's plan states it
is real-time for that exchange. Default for every free plan is `delayed`/`endOfDay`.

## 2. Provider assessment

| Provider | Status / maintenance | Free tier (as researched) | Coverage relevant to InvestiQ | Delay | History | Caching / display rights | Decision |
|---|---|---|---|---|---|---|---|
| **Alpha Vantage** | Active | 25 requests/day, ~5/min; compact output (100 points) on free keys; premium from ~USD 49.99/mo (third-party figures) | Global quotes incl. some EU exchanges (`.LON`, `.DEX`, …), daily series, company overview (US), FX, news & sentiment | EOD/delayed on free | Full daily history premium-only | Free key for personal use; redistribution restricted — verify ToS | **Adapter v1** (search, quote, daily series, overview, FX, news) |
| **Finnhub** | Active | 60 calls/min (+30/s cap); candles are premium (free returns 403) | US quotes, company profile, basic financials (`/stock/metric`), company & general news, earnings calendar | Delayed/real-time for US per plan | Candles premium | Free plan personal use; check ToS for display | **Adapter v1** (quote, profile, metrics, news, earnings calendar) |
| **Twelve Data** | Active | Basic: 8 credits/min, 800/day; US equities, forex, crypto; EU exchanges from paid tiers | Time series, quote, symbol search with MIC codes | Depends on plan | Deep for US | Plan-dependent; verify | **Adapter v1** (search, quote, time series) |
| **Financial Modeling Prep** | Active, `stable` API | Basic: 250 calls/day, EOD, 5 years history, personal licence; Starter USD 29/mo | Profile with ISIN, quote, EOD history, statements, ISIN search | EOD on free | 5 years free | Personal licence on free; commercial licensed separately | **Adapter v1** (profile, quote, history, ISIN search, fundamentals) |
| **Massive** (formerly Polygon.io; `api.massive.com`, `api.polygon.io` still accepted) | Active, rebranded 2025 | Stocks Basic: 5 calls/min, EOD, 2 years history; Starter USD 29/mo (15-min delayed) | US stocks only | EOD free | 2 years free | Verify ToS | **Adapter v1** (prev close, aggregates, ticker search) |
| **FRED** (St. Louis Fed) | Active | Free API key required; rate-limited (contact FRED for more) | US macro series (CPI, unemployment, rates) | — | Long | Terms require key; **some series are copyrighted by third parties** — only public-domain series are preselected; user responsible for others | **Adapter v1** (macro series) |
| **ECB Data Portal** (`data-api.ecb.europa.eu`, SDMX REST, `format=csvdata`) | Active, no key | Free | Euro FX reference rates (published ~16:00 CET on TARGET days), interest rates, HICP | Daily | Long | Free reuse with attribution (ECB reuse policy) | **Adapter v1** (FX `EXR`, macro) |
| **Czech National Bank** (`api.cnb.cz/cnbapi/exrates/daily`, JSON; legacy `daily.txt`) | Active, no key | Free | CZK fixing for ~30 currencies (working days after 14:30 CET) | Daily | Per date | Public data; attribution | **Adapter v1** (FX) |
| **SEC EDGAR** (`data.sec.gov`) | Active, no key | Free; max 10 requests/s; **requires a declared User-Agent with contact e-mail** | XBRL company facts for US filers (revenue, net income, EPS, debt, cash flow), ticker→CIK map | Filing-based | Since ~2009 | US public data | **Adapter v1** (fundamentals) — user must enter their contact e-mail; disabled until then (privacy) |
| **Official IR pages / exchanges / agencies** | Varies | Free web pages, no stable API | Annual reports, KID documents, issuer terms | — | — | Copyright of publishers; link only | Links only (no scraping) |
| **RSS of official institutions** (ECB press, Fed press, CNB press, Eurostat, SEC press) | Active | Free | Central bank decisions, data releases, regulatory news | — | — | Headline + short summary + link only | **News adapter v1** |

### Gaps (honest limitations)

* **Bonds:** no free API provides EU/CZ bond quotes, YTM or ratings. InvestiQ computes bond
  analytics (YTM, duration, accrued interest, schedules) locally from **user-entered terms and
  prices** (or demo data). `BondDataProvider` exists as an extension point; no live bond adapter ships.
* **ETFs (UCITS):** no free API for holdings, TER, tracking difference or KID. `ETFDataProvider`
  is an extension point; v1 supports manual entry (with source URL and date) and demo data. KID
  availability is shown as "unknown" unless the user records a source.
* **Economic calendar:** no free comprehensive API. v1 combines a bundled, source-linked schedule of
  central-bank decision dates (ECB, Fed, CNB) that must be refreshed each year, Finnhub earnings
  calendar (US), and user-added events.
* **Quote delays:** free tiers are delayed or end-of-day. The UI never calls them real-time.
* **Commercial use:** most free tiers are personal-use only. A public release requires commercial data
  licences — see `LEGAL_COMPLIANCE.md` §6.

## 3. Endpoint contract summary (as implemented)

| Adapter | Endpoint(s) | Notable parsing rules |
|---|---|---|
| Alpha Vantage | `GLOBAL_QUOTE`, `TIME_SERIES_DAILY`, `SYMBOL_SEARCH`, `OVERVIEW`, `NEWS_SENTIMENT`, `FX_DAILY` | Keys like `"05. price"`; rate-limit and errors arrive as HTTP 200 with `Information`/`Note`/`Error Message` → mapped to `rateLimited`/`invalidRequest`; `"None"`/`"-"` → missing |
| Finnhub | `/quote`, `/stock/profile2`, `/stock/metric?metric=all`, `/company-news`, `/news`, `/calendar/earnings` | Unknown symbol returns all-zero quote (`c=0,t=0`) → `notFound`, never a zero price; 403 → `notSupported` (premium) |
| Twelve Data | `/symbol_search`, `/quote`, `/time_series` | Numbers as strings; errors as `{"status":"error","code":…}` with HTTP 200 |
| FMP | `/stable/quote`, `/stable/profile`, `/stable/historical-price-eod/full`, `/stable/search-isin` | Arrays; 401 body `"Error Message"`; ISIN from profile |
| Massive | `/v2/aggs/ticker/{t}/prev`, `/v2/aggs/ticker/{t}/range/1/day/{from}/{to}`, `/v3/reference/tickers` | Millisecond epoch timestamps; `status` field |
| ECB | `/service/data/EXR/D.{CCY}.EUR.SP00.A?format=csvdata&lastNObservations=n` | Columns located **by header name** (`TIME_PERIOD`, `OBS_VALUE`, `CURRENCY`, `CURRENCY_DENOM`); rates are units of CCY per 1 EUR |
| CNB | `/cnbapi/exrates/daily?date=YYYY-MM-DD&lang=EN` (JSON `rates[]`: `validFor`, `order`, `country`, `currency`, `amount`, `currencyCode`, `rate`) | `rate` is CZK per `amount` units (e.g. JPY amount 100) → normalised to per-unit |
| FRED | `/fred/series/observations?series_id=…&file_type=json` | `value` is a string; `"."` means missing |
| SEC EDGAR | `/files/company_tickers.json`, `/api/xbrl/companyfacts/CIK##########.json` | CIK zero-padded to 10 digits; facts by `us-gaap` tag and unit; duplicates across filings resolved by latest `filed`; frames used for annual values |
| RSS/Atom | Feed URLs on an allow-list | Item caps (200/feed), size cap, HTML stripped to plain text, summary truncated |

**Contract-test fixtures** in `InvestiQKit/Tests/InvestiQDataTests/Fixtures` were constructed from the
official API documentation, because the development sandbox could not reach the providers. They must
be refreshed against live responses before release (`scripts/refresh_fixtures.md`). The app's Settings
→ Data Providers screen includes a **"Test connection"** action that validates a live response against
the same decoders.

## 4. Caching policy

| Data | TTL (fresh) | Served when stale? |
|---|---|---|
| Quote | 15 min (delayed plans) / until next close (EOD) | Yes, labelled `stale` with age |
| Daily history | Until next trading day | Yes |
| Fundamentals / overview | 7 days | Yes |
| FX rates (ECB/CNB) | Until next publication | Yes |
| News | 30 min | Yes |
| Calendar | 24 h | Yes |

Cached data is stored only in the encrypted cache DB, only for the user's own use on their device. If a
provider's terms forbid local caching, its adapter sets `cachePolicy = .memoryOnly`.

## 5. User configuration

Settings → Data Providers: enable/disable, priority order, API key entry (stored in Keychain, masked,
never displayed again), SEC contact e-mail (explicit explanation that it is sent to the SEC in the
User-Agent header), connection test, and a link to each provider's terms page.

## 6. News and economic calendar

**Official press releases** (provider `official`, no key, enabled by default, fetched only when the user
opens or refreshes News; verified 2026-11-25):

| Institution | Feed |
|---|---|
| European Central Bank | `https://www.ecb.europa.eu/rss/press.xml` |
| Federal Reserve Board | `https://www.federalreserve.gov/feeds/press_all.xml` (listed as "All Press Releases" on https://www.federalreserve.gov/feeds/feeds.htm) |
| Česká národní banka | `https://www.cnb.cz/cs/.content/rss-feed/rss-feed_tz.rss` (listed on https://www.cnb.cz/cs/obecne/rss/) |

Feeds are untrusted input: markup is stripped, entities decoded, only `https` links kept, at most 200
items per feed, descriptions cut to 300 characters; nothing is rendered as HTML. Finnhub (with a key)
adds market and company news. Demo sessions use synthetic items whose links (`.invalid`) are never opened.

**Economic calendar.** `InvestiQContent/Resources/calendar/events.json` contains only dates checked
against the institutions' own pages on 2026-11-25, each with its source URL:
ECB monetary policy meetings (17 Dec 2026; 2027: 4 Feb, 18 Mar, 29 Apr, 10 Jun, 22 Jul, 9 Sep, 28 Oct,
16 Dec — https://www.ecb.europa.eu/press/calendars/mgcgc/html/index.en.html); FOMC (8–9 Dec 2026;
2027 per the revised tentative schedule of 12 Nov 2026: 26–27 Jan, 16–17 Mar, 27–28 Apr, 8–9 Jun,
27–28 Jul, 14–15 Sep, 26–27 Oct strategy discussion only, 16–17 Nov moved from December —
https://www.federalreserve.gov/newsevents/pressreleases/monetary20261112a.htm); ČNB monetary policy
meetings (17 Dec 2026; 2027: 4 Feb, 25 Mar, 6 May, 23 Jun, 5 Aug, 23 Sep, 4 Nov, 16 Dec); ČSÚ CPI flash
and final for November 2026 (4 and 10 Dec 2026); Eurostat HICP flash and final for December 2026
(6 and 19 Jan 2027, per the ECB statistical calendar); selected BLS CPI and Employment Situation
releases in 2027 (https://www.bls.gov/schedule/2027/home.htm). Times are stored only where the source
states them (FOMC statement 14:00 and BLS releases 08:30, New York time); the ECB, ČNB, ČSÚ and Eurostat
entries are date-only. Events carry `tentative` / `rescheduled` status and the previous date. Earnings
dates come from Finnhub (or the demo provider) for instruments in the user's library. **Limitation:** the
bundled list must be refreshed with each release (see docs/reports/KNOWN_LIMITATIONS.md); dates after
the listed ones are not shown rather than guessed.

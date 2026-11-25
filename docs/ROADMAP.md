# InvestiQ — Roadmap

Each phase ends with: build → tests → verification → fixes → documentation update → commit.
Status legend: ✅ done · 🟡 in progress · ⬜ not started · ⚠️ done with documented limitations.

| Phase | Scope | Completion criteria | Status |
|---|---|---|---|
| 0 Research & architecture | Requirements, API research, architecture, DB, security, UI wireframes, legal constraints | All `docs/*.md` written and consistent | ✅ |
| 1 Foundation | Package, Xcode project, navigation, design system, local DB, authentication, onboarding, settings, CI | Linux tests green; macOS CI builds the app; profile create/lock/unlock works | ✅ (CI run 3: macOS build + UI tests green) |
| 2 Market data | Provider protocols, gateway, first providers, Market Explorer, watchlist, asset details, charts, validation, caching | Contract tests green; demo mode shows explorer with labelled synthetic data | ✅ |
| 3 Portfolio | Transactions, ledger, calculations, charts, currency conversion, CSV import/export | Financial calculation tests green | ✅ |
| 4 Analytics & risk | Stock/ETF/bond analysis, risk engine, scenarios, forecast validation | Analytics/forecast tests green | ✅ |
| 5 News & education | News, calendar, classification, education, planner, simulator, broker directory | Tests green; content complete in ru/en/cs | ✅ |
| 6 Optional AI | AIProvider, Ollama/external/Apple FM adapters, privacy controls, AI security tests | Tests green; app fully functional with AI off | ⬜ |
| 7 Production prep | Security audit, performance profiling, accessibility, migration tests, release config, signing prep, sandbox verification, legal & licensing checklists | Reports written; known limitations listed | ⬜ |

## Future (post-v1)

* iOS/iPadOS app reusing `InvestiQKit` (only the app target and adapters are platform-specific).
* FIFO / specific-lot cost basis and Czech tax-time-test helper (requires professional tax review).
* Licensed EU data (bond quotes, UCITS ETF data) once a commercial data agreement exists.
* Optional end-to-end encrypted sync (would require a new threat model).
* SQLCipher-based paging encryption if user data volume outgrows the in-memory model.

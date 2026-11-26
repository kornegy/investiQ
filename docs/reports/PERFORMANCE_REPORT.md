# InvestiQ — Performance report

Measured 2026-11-25 by `PerformanceBenchmarks` (package tests) in a **debug** build on Linux
(Docker `swift:6.2-noble`, 4 vCPU Intel Xeon @ 2.30 GHz, 15 GB RAM). Release builds on Apple Silicon are
expected to be faster; Instruments profiling on a Mac has not been done yet (see "Next steps").

| Operation | Size | Time (debug) | Ceiling in test | Where it runs |
|---|---|---|---|---|
| Ledger replay | 10 000 transactions, 20 instruments | 134 ms | 5 s | `PortfolioService` actor (off the main thread) |
| Ledger hash (SHA-256 of canonical JSON) | 10 000 transactions | 243 ms | 5 s | per snapshot |
| Encrypted save (serialize + AES-GCM + atomic rename) | DB with 10 000 transactions | 10 ms | 3 s | after each user write |
| Encrypted open (decrypt + deserialize) | same | 47 ms | 3 s | unlock |
| Argon2id key derivation (t=3, m=64 MiB) | 1 derivation | 62 ms | 10 s | unlock, password change, backup |
| Walk-forward validation, bootstrap model (2 000 paths) | 10 years daily, horizon 21 | 1.96 s | 60 s | `Task.detached` on user request |
| Risk report (exposures, HHI, correlations, VaR) | 20 holdings × 252 returns | 9 ms | 5 s | `RiskService` actor |
| Strategy back-test | 3 assets, 10 years daily, quarterly rebalancing | 863 ms | 10 s | `SimulatorService` actor |
| News classification + deduplication | 500 items | 94 ms | 20 s | `NewsService` actor |

## Design measures

* All database, network and analytics work runs in actors or detached tasks; view models only publish
  results (`@MainActor @Observable`).
* SQLite runs in memory; encrypted persistence is a single sequential write. User data is small (the
  10 000-transaction ledger image is a few MB).
* Charts are down-sampled (≤ 500 points for prices, ≤ 400 per series for back-tests).
* Network: per-provider token buckets, daily quotas, in-flight de-duplication, encrypted HTTP cache,
  freshness windows; provider searches only on explicit request.
* News and calendar are fetched only when the section is opened or refreshed; notifications are checked
  at most every 30 minutes while the app runs.

## Observations and follow-ups

* Walk-forward validation of the bootstrap model is the slowest user-triggered task (~2 s debug). It
  shows a progress indicator and does not block the UI; a release build should be several times faster.
  If it is still slow on low-end Macs, reduce paths during validation (documented parameter).
* The ledger hash encodes JSON for every snapshot; for very large ledgers this could be cached per
  ledger version.
* To do on a Mac before release: Instruments (Time Profiler, Allocations, Leaks) on a profile with
  10 000 transactions and 50 instruments; launch time; memory after a full Learn/News/Risk session.

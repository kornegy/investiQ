# InvestiQ — Known limitations

Honest list of what does not work, works partially or was not verified. Nothing here is hidden in the UI.

## Data

* **Free data tiers:** quotes are delayed or end-of-day and labelled so; free plans have daily quotas.
  No licensed real-time data. European bond quotes and UCITS ETF fact sheets are not available from the
  supported free APIs — bond/ETF facts can be entered manually; missing data is shown as missing.
* **Provider formats were not verified live:** the development container blocks provider hosts, so
  adapters were tested against documented/recorded response formats. First use with real keys must be
  checked (Settings → Data Providers → Test connection).
* **Dividend calendar:** no supported free provider gives future dividend payment dates; dividend
  notifications therefore work only in the demo (synthetic) and for data entered by the user.
* **Economic calendar:** the bundled list contains only dates verified on 2026-11-25 (ECB, Fed, ČNB
  through 2027; selected ČSÚ, Eurostat and BLS releases). Later dates are not shown rather than guessed;
  the list must be updated with each release. Times are stored only where the source states them.
* **Broker directory:** six firms; legal entity, supervisor, compensation scheme verified from official
  sources on 2026-11-25. Fees, FX fees, minimums, age limits and instruments are deliberately shown as
  "not verified". Some open questions (e.g. which group entity serves Czech clients) are listed.
* **News:** Finnhub (key required) and official press releases of ECB, Fed and ČNB. Classification is
  rule-based (English/Czech keywords) and can be wrong; the cue that triggered it is shown.

## Analytics

* Average-cost basis only (no FIFO/specific lots); no tax calculation (Czech time test etc.).
* Portfolio VaR/volatility use local-currency returns at current weights (FX moves not included).
* Bond analytics assume no default and use street conventions; floating-rate and inflation-linked bonds
  are not modelled. Bond ETFs use an assumed duration of 7 years in rate stress tests (labelled).
* Forecast models are deliberately simple (naive, drift, block bootstrap) and usually do not beat the
  naive baseline — the app says so. Scenario ranges are price-only (no dividends).
* The strategy back-test uses monthly FX rates and no taxes.

## Platform

* Built and UI-tested only on GitHub's macOS 26 runners; never run interactively by the developer.
  Manual testing on macOS 14 and 26 is required (see TESTING_REPORT.md and ACCESSIBILITY_REPORT.md).
* Touch ID requires a signed build with a team ID (Data Protection Keychain); with "Sign to Run Locally"
  Touch ID is reported as unavailable.
* Apple Foundation Models require macOS 26 on supported hardware with Apple Intelligence; the adapter
  compiles but was not run on such hardware.
* Notifications are evaluated only while the app runs (no background agent).
* No iCloud sync; backups are manual files.

## Process

* No pull request exists because the remote repository has no base branch (only the development
  branch). Creating `main` was not done without permission.
* No external security, legal, data-licensing or App Store review has been performed. The app must not
  be called production-ready until they are (spec §36).

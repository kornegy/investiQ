# InvestiQ — Legal & Regulatory Compliance Notes

> **This is an engineering research summary, not legal advice.** InvestiQ does **not** claim legal
> compliance. Before any public release (including the Mac App Store), the product must be reviewed by
> a qualified lawyer specialised in EU/Czech financial regulation and data protection, and data
> licences must be reviewed. A disclaimer does **not** by itself remove regulatory obligations.

Research date: 2026-11-24.

## 1. Classification of app functions

| Category | Examples in InvestiQ | Regulatory sensitivity | v1 design |
|---|---|---|---|
| Educational information | Lessons, glossary, calculators, quizzes | Low | Included |
| Market data | Quotes, history, FX, fundamentals with source | Low–medium (data licensing) | Included, with sources and delay labels |
| General financial analysis | Volatility, drawdown, ratios, bond math, neutral statuses, hypothetical stress tests | Medium (must not become a recommendation; MAR presentation rules if recommendations were produced) | Included, neutral, explained, method-linked |
| Personalised investment recommendation | "You should buy ETF X", ranking instruments as suitable for the user | **High — MiFID II investment advice requires authorisation** | **Excluded** |
| Execution of transactions / order routing / account connection | Placing orders, connecting brokers | **High — investment service/reception & transmission of orders** | **Excluded** |

## 2. MiFID II — investment advice

* MiFID II Art. 4(1)(4) defines investment advice as "the provision of personal recommendations to a
  client … in respect of one or more transactions relating to financial instruments". Delegated
  Regulation (EU) 2017/565 Art. 9: a recommendation is *personal* when it is presented as suitable for
  the person or based on consideration of that person's circumstances, and not issued exclusively to
  the public.
* ESMA's supervisory briefing on the definition of advice (ESMA35-43-3861, 2023) explicitly covers
  apps, websites and social media, filtering, model portfolios and disclaimers, and states that
  recommendations made through investment apps **could** be personal recommendations, and that
  disclaimers or ignoring known client information do not avoid the qualification.
* **Design consequences (binding for development, see `CLAUDE.md`):**
  1. Onboarding answers are used **only** for safety education (emergency fund, debt, horizon
     explanations) and for presentation (language, currency, educational mode). They are **never**
     used to select, filter, rank, or label specific instruments or allocations as suitable.
  2. No feature outputs "buy/sell/hold", target prices, "suitable for you", or model portfolios for
     the user.
  3. Analytical statuses are neutral and rule-based, identical for every user.
  4. Broker directory has no ranking, no referral/affiliate links, no sponsored placement.
  5. Simulator allocation tests use allocations chosen by the user.

## 3. Czech law

* Act No. 256/2004 Coll. on Capital Market Undertakings (ZPKT): investment advice concerning investment
  instruments is an investment service; providing it requires authorisation by the Czech National Bank
  (ČNB) (investment firm, or e.g. investment intermediary within the statutory limits).
* ČNB supervises consumer protection in financial services; misleading presentation of risk/return can
  be a consumer-protection issue.
* Act No. 110/2019 Coll. (personal data processing): age of digital consent in Czechia is **15**.

## 4. Market Abuse Regulation (MAR)

Regulation (EU) No 596/2014 Art. 20 and Delegated Regulation (EU) 2016/958 impose objective-presentation
and conflict-of-interest disclosure rules on persons producing or disseminating **investment
recommendations** (information recommending or suggesting an investment strategy). InvestiQ avoids
producing recommendations; neutral statuses and their rules are disclosed. To be confirmed by counsel.

## 5. PRIIPs and UCITS

* PRIIPs Regulation (EU) No 1286/2014: a Key Information Document (KID) must be provided before a
  PRIIP (including ETFs/UCITS since 1 Jan 2023) is made available to retail investors in the EEA. Many
  US-domiciled ETFs have no PRIIPs KID, so EU brokers generally do not offer them to retail clients.
  InvestiQ shows "KID availability" and explains this; it never suggests ways around it.
* UCITS Directive 2009/65/EC: UCITS status is shown when known (from a recorded source), otherwise
  "unknown".

## 6. Data licensing

* Most free API tiers are licensed for personal, non-commercial use (e.g. FMP Basic "personal licence";
  Alpha Vantage, Finnhub free tiers — see `DATA_PROVIDERS.md`). A commercial distribution where the app
  uses **the user's own keys** still needs a licence review; bundling the developer's keys is not
  permitted by v1 design (no keys ship with the app).
* Real-time exchange data generally requires exchange agreements; v1 never labels free data as
  real-time.
* News: only headline, short provider summary and link are displayed (no full-text reproduction).
* ECB/CNB/SEC/FRED: public data with attribution; some FRED series are third-party copyrighted.

## 7. GDPR

* Local-first: personal and financial data stay on the device; the developer receives nothing.
* Data sent to third parties only on user action/configuration: symbols/queries and IP address to market
  data providers; SEC contact e-mail (if entered) in the User-Agent; prompts to an external AI only with
  explicit consent and minimised content.
* Data subject rights are implemented locally: export (JSON/CSV), deletion (profile deletion), rectification
  (editing). No profiling for marketing, no tracking, no telemetry.
* Drafts: `legal/PRIVACY_POLICY_DRAFT.md`.

## 8. Apple App Store

* Privacy manifest (`PrivacyInfo.xcprivacy`) with required-reason API declarations; App Privacy
  "Data Not Collected" (to be confirmed at submission).
* Guideline 5.1.1(ix): apps in highly regulated fields (banking/financial services) should be
  submitted by a legal entity providing the service — counsel to confirm whether an educational tool
  without services is affected.
* Guidelines on accurate metadata, no misleading claims, and age rating (the app includes
  educational mode for minors; rating to be determined).

## 9. Minors

Profiles with age category under 18: educational mode only (virtual portfolios, education, planner in
educational form). No broker sign-up/funding links, no guidance on real trades, no help circumventing
age limits. Parental-consent requirements for data processing do not arise from local-only processing,
but external AI is disabled for minors.

## 10. Required documents (drafts in `docs/legal/`)

* `PRIVACY_POLICY_DRAFT.md`
* `TERMS_OF_USE_DRAFT.md`
* `FINANCIAL_RISK_DISCLOSURE.md`
* `DATA_SOURCES_DISCLOSURE.md`
* `FORECAST_METHODOLOGY_DISCLOSURE.md`

## 11. Pre-release legal checklist

- [ ] Counsel review of feature classification (§1) under MiFID II/ZPKT/MAR
- [ ] Review of all user-facing copy (ru/en/cs) for implied recommendations
- [ ] Data licence review for each enabled provider
- [ ] Privacy policy and terms finalised; controller identity and contact defined
- [ ] App Store submission entity and age rating decided
- [ ] Broker directory: verification process and liability review

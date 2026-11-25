# Legal review and data-licensing checklist

This project contains **drafts** only. Nothing here is legal advice; a qualified lawyer (CZ/EU financial
regulation, consumer protection, GDPR) must review before any release.

## Regulatory positioning (see LEGAL_COMPLIANCE.md)
- ⚖️ Confirm the app is not investment advice under MiFID II: neutral statuses only, no personal
  recommendations, onboarding answers never used to select or rank instruments.
- ⚖️ Confirm the broker directory is informational (alphabetical, no ranking, no referral links,
  verified facts only) and not a financial promotion or tied-agent activity.
- ⚖️ Confirm minors' educational mode (no external links to brokers, virtual money only, no external AI)
  satisfies consumer-protection expectations.
- ⚖️ Review all user-facing copy in ru/en/cs for promissory or manipulative language (an automated lint
  exists; human review still required).

## Documents to finalise
- ⚖️ Privacy policy (`docs/legal/PRIVACY_POLICY_DRAFT.md`): local-only processing, providers chosen by
  the user, optional AI with consent, no telemetry.
- ⚖️ Terms of use, financial risk disclosure, data-sources disclosure, forecast-methodology disclosure.
- ⚖️ Imprint/contact and support channel.

## Data licensing (per provider)
| Provider | Key | Questions for review |
|---|---|---|
| Alpha Vantage, Finnhub, Twelve Data, FMP, Massive | user-supplied | Do free/paid terms allow use inside a third-party desktop app with the user's own key? Local caching duration? Attribution? Display of delayed data? |
| SEC EDGAR | none (User-Agent with contact e-mail) | Fair-access policy and rate limits respected; contact e-mail supplied by the user |
| FRED | user-supplied | Terms of use for display and caching |
| ECB, ČNB exchange rates and press feeds | none | Reuse conditions and attribution |
| Fed press feed | none | Public domain status confirmed? |
| Economic calendar (bundled) | — | Facts from official calendars; confirm no database rights issue |
| Broker directory (bundled) | — | Facts from official registers and firms' legal documents; liability for outdated data; update process |
| Claude API (optional AI) | user-supplied | Anthropic terms apply to the user's own account; app shows consent and what is sent |

## Open decisions for the owner
- ⚖️ Distribution channel (Mac App Store vs direct download with notarisation).
- ⚖️ Who maintains the bundled calendar and broker data, and how often (proposal: before every release
  and at least quarterly, with the verification date shown in the app).

# Mac App Store publication checklist

Legend: ✅ done in the project · ⬜ to do · ⚖️ needs a legal/business decision.

## Build and signing
- ⬜ Apple Developer Program membership; set Team ID and a real bundle identifier (currently
  `com.example.InvestiQ`) in the target's Signing & Capabilities.
- ⬜ Provisioning profile for Mac App Store distribution; enable Keychain Sharing only if needed (not
  needed today).
- ✅ App Sandbox enabled; entitlements limited to network client and user-selected files.
- ✅ Hardened Runtime enabled.
- ⬜ Archive with Release configuration; validate in Xcode Organizer; `codesign --verify --deep --strict`.
- ⬜ App icon set (`AppIcon` has no images yet) and Mac App Store screenshots in ru/en/cs.
- ⬜ Version and build numbers; `LSApplicationCategoryType` = `public.app-category.finance` (or
  education ⚖️).

## Privacy
- ✅ No tracking, no analytics SDKs, no advertising identifiers.
- ✅ `PrivacyInfo.xcprivacy` present; ⬜ re-verify required-reason API declarations against the final
  binary (UserDefaults is declared; the app code itself does not call it).
- ⬜ App Store privacy "nutrition label": data not collected by the developer; note that the user's
  chosen third-party data and AI providers receive requests (symbols, questions) under their own terms.
- ⚖️ Publish the privacy policy (draft: `docs/legal/PRIVACY_POLICY_DRAFT.md`) at a public URL.

## Content and guidelines
- ✅ No trade execution, no brokerage connections, no buy/sell signals, no target prices.
- ✅ Disclaimers on analytical screens; financial risk disclosure draft.
- ⚖️ Age rating: the app contains financial education and a simulator without real money; minors get
  educational mode. Decide the rating questionnaire answers (no gambling, no real-money trading).
- ⚖️ App Review guideline review for financial apps (no regulated activity is performed; confirm that
  the broker directory is informational and not a financial promotion).
- ✅ Users supply their own API keys; explain in review notes that the app is fully usable in demo mode
  without keys (provide demo instructions to App Review).
- ⬜ Review notes: how to test (Try demo → all sections), that AI is optional and off by default.

## Export compliance
- ⚖️ Encryption: AES-GCM and Argon2id via CryptoKit/libsodium for data protection. Determine the export
  classification (typically exempt for data-at-rest protection) and set
  `ITSAppUsesNonExemptEncryption` accordingly.

## Legal and licensing
- ⚖️ Terms of use, financial risk disclosure, data-source and forecast-methodology disclosures
  (drafts in `docs/legal/`) reviewed by a lawyer for CZ/EU (MiFID II, consumer law, GDPR).
- ⚖️ Data provider terms permit use in a distributed app with user-supplied keys and local caching (see
  LEGAL_AND_LICENSING_REVIEW.md).
- ✅ Third-party licences listed in `THIRD_PARTY_NOTICES.md`; ⬜ show them in an in-app acknowledgements
  screen with full licence texts.

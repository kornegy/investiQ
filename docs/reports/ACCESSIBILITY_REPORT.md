# InvestiQ — Accessibility report

Status: implemented by design and reviewed in code; **manual testing with VoiceOver and keyboard-only
use on a Mac is still required** (the development environment has no macOS GUI).

## Implemented

* Standard SwiftUI controls throughout (forms, pickers, toggles, steppers, lists) so VoiceOver, Full
  Keyboard Access and system text sizes work without custom handling.
* 34 explicit accessibility annotations: labels for icon-only buttons (delete, info, chart images),
  combined elements for metric tiles, stress cards, forecast records and news items, identifiers used by
  UI tests, header traits for banners.
* Information is never conveyed by colour alone: changes use sign, arrow glyph and colour; risk levels
  use text plus distinct symbols; statement types and statuses are text badges.
* Colour-blind-safe palette option (Settings → General).
* Keyboard: menu commands ⌘1…⌘0 for the ten sections, ⌘L to lock, default and cancel actions in sheets
  and dialogs, `onSubmit` in text fields.
* Charts have accessibility labels; every chart is accompanied by the key numbers as text.
* Plain-language copy, short lessons with analogies, tooltips explaining every metric.
* Localisation in Russian, English and Czech with locale-aware number, currency and date formatting.

## Manual test checklist (to be completed on macOS 14 and 26)

- [ ] VoiceOver: complete onboarding, add a transaction, read the dashboard, open a lesson and pass a
      quiz, run a simulator order, change settings.
- [ ] Full Keyboard Access: every control reachable and operable; focus order logical.
- [ ] Increase contrast, reduce transparency, reduce motion: no information lost.
- [ ] Largest system text size: no clipped text in cards and grids.
- [ ] Colour-blind palette with Color Filters (protanopia, deuteranopia, tritanopia).
- [ ] Charts: VoiceOver reads the summary values next to each chart.
- [ ] Accessibility Inspector audit with no errors.

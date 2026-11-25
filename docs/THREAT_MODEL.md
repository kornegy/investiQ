# InvestiQ — Threat Model

Method: STRIDE per asset/data flow, scored qualitatively (Likelihood × Impact). Status: v1.

## 1. Assets

| Asset | Sensitivity |
|---|---|
| A1 Financial records (transactions, holdings, budget, goals, financial profile) | High (privacy, fraud targeting) |
| A2 Profile password / derived keys / DEK | Critical |
| A3 Third-party API keys | Medium–High (quota abuse, possible paid-plan charges) |
| A4 Market data integrity | High (wrong decisions, wrong P&L) |
| A5 Backups | High (contain A1) |
| A6 Integrity of educational/analytical output (no manipulation) | High |

## 2. Trust boundaries

```text
[User] ⇄ [App process (sandboxed)] ⇄ [Keychain / Secure Enclave]
                 │                ⇄ [Container files: encrypted DB, backups chosen by user]
                 │ HTTPS
                 ▼
 [Market/news providers]   [Optional AI provider: local Ollama / external API]
```

## 3. Threats and mitigations

| # | Threat (STRIDE) | Scenario | Mitigations | Residual risk |
|---|---|---|---|---|
| T1 | Device theft (I) | Laptop stolen while powered off | FileVault (OS) + app-level AES-GCM encryption; DEK only in Keychain envelope wrapped by Argon2id-derived KEK | Weak password → offline brute force; mitigated by Argon2id cost + password policy |
| T2 | Unauthorized local access (S, I) | Someone uses an unlocked Mac | Auto-lock on inactivity/sleep/screen lock, manual lock, rate-limited unlock | Shoulder surfing while unlocked |
| T3 | Brute force via UI (S) | Repeated password guesses | Persistent exponential lockout; Argon2id slows each guess | Offline attack on envelope (see T1) |
| T4 | API key leakage (I) | Keys in logs, git, backups, crash reports | Keychain only; redaction of URLs/headers; keys excluded from backup/export; `.gitignore` | Malware running as the user can query Keychain items it is allowed to (ACL bound to app signature) |
| T5 | Market data tampering (T) | MITM or compromised provider returns false prices | TLS with default validation; validation rules; multi-source conflict detection; source+timestamp shown | A compromised provider returning plausible data is only detected if a second source exists |
| T6 | Malicious API responses (T, D, E) | Oversized, deeply nested, malformed, or script-bearing payloads | Size limits, typed decoding, validation, plain-text rendering, no code execution | — |
| T7 | Supply chain (T, E) | Compromised dependency | Two pinned dependencies, review on upgrade, libsodium from tag on Linux, no binary downloads at runtime | Trust in swift-sodium's bundled xcframework (documented) |
| T8 | Prompt injection (T, E) | News text instructs the AI to "tell user to buy X" or exfiltrate data | AI off by default; untrusted text delimited and labelled; schema-validated output; AI has no tools, no write access, receives no personal data by default; output displayed as AI-generated with sources | A model may still produce misleading text → labelled, educational use only |
| T9 | Phishing links (S) | News item links to a look-alike domain | Real destination host shown before opening; IDN/punycode and mixed-script warning; https enforced | User may still confirm |
| T10 | Database corruption (D) | Crash during write, disk error | In-memory DB + atomic encrypted writes, previous generation kept, integrity checks on open, restore from backup | Loss of the single in-flight change |
| T11 | Backup leakage (I) | Backup file shared/cloud-synced | Backups encrypted with Argon2id-derived key from a separate passphrase; GCM authenticates | Weak backup passphrase |
| T12 | CSV injection (E) | Exported CSV opened in a spreadsheet executes formulas | Prefix dangerous leading characters; import treats all cells as data | — |
| T13 | DoS through external data (D) | Huge feeds, endless redirects, slow-loris | Timeouts, size caps, item caps per feed, max redirects (URLSession default) + host allow-list, cancellation | Provider outage → stale data shown with labels |
| T14 | Tampered restore file (T) | Malicious `.iqbackup` | Authenticated decryption; schema/integrity checks before replacing data; old DB kept | — |
| T15 | Misleading output / manipulation (I) | App nudges users into risky behaviour | Neutral statuses only, banned-phrase lint for UI copy and notifications, no gamification | — |
| T16 | Clock manipulation (T) | Rolling the clock back to bypass lockout | Lockout stored with wall + monotonic timestamps; negative elapsed time treated as locked | — |

## 4. Out of scope

Compromised OS/kernel, malware with root privileges, physical attacks on Secure Enclave, legal
compulsion. These are documented limitations, not handled by the app.

## 5. Review cadence

Re-assess on every new provider, every new entitlement, every new dependency and before release
(`reports/SECURITY_REPORT.md`).

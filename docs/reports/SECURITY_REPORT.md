# InvestiQ — Security report (internal review)

Date: 2026-11-25. This is an internal engineering review against `docs/SECURITY.md` and
`docs/THREAT_MODEL.md`, **not** an independent audit. An external security review is required before
calling the app production-ready (spec §36).

## Scope and method

Code review of all modules, targeted searches (forbidden APIs, logging, plaintext transport, `try?` on
user-data paths, force unwraps, secrets in code), review of entitlements and build settings, and the
automated security tests listed in TESTING_REPORT.md.

## Controls verified

| Area | Control | Evidence |
|---|---|---|
| Passwords | Never stored; Argon2id (libsodium, t=3, m=64 MiB) derives a key that unwraps the data key (AES-GCM) | `PasswordKDF`, `KeyEnvelope`, `CryptoTests` (known-answer vector) |
| Brute force | 5 free attempts, then 30 s doubling to 15 min; persisted; clock rollback counts as locked | `LoginThrottle`, `AuthHardeningTests` |
| Data at rest | Whole SQLite image AES-256-GCM encrypted, header authenticated, atomic write, previous generation kept | `EncryptedDatabaseFile`, `EncryptedStoreTests` |
| Keys | Per-profile DEK in Keychain envelope; HKDF subkeys per database; Touch ID via Data Protection Keychain with `.biometryCurrentSet` | `SecureStoreService`, `KeychainBiometricKeyStore` |
| API keys | Keychain only (per profile); redacted from URLs/headers/log keys; never in DB, preferences, exports or backups | `KeychainCredentials`, `Redactor`, `BackupTests`, export test |
| Backups | Separate passphrase, Argon2id, AES-GCM, authenticated header, KDF bounds against crafted files, restore validated before replacing | `BackupFile`, `BackupTests` |
| Transport | HTTPS only (TLS validation never changed), ephemeral session without cookies/URL cache, response size limits; plain HTTP only to loopback (local AI) | `URLSessionHTTPClient`, `HTTPRequest.usesAllowedTransport` |
| Untrusted content | News/RSS rendered as plain text, markup stripped, `https` links only, item/size caps; external links show the real host and need confirmation; IDN homograph detection | `OfficialNewsProvider`, `LinkSafety` |
| CSV | Formula-injection neutralised on export; import treats cells as data with limits | `CSVSanitizer`, `CSVParser` |
| AI | Off by default, consent, minors blocked, minimisation, secret scan, injection defences, strict schema, no tools | `AIService`, `PromptGuard`, `AISecurityTests` |
| Minors | Educational mode: virtual portfolios only, no broker websites, no external AI | `AppFlowTests` |
| Privacy | No telemetry or analytics SDKs; network only to providers the user enabled (plus ECB/ČNB rates and official press feeds, documented and switchable) | code search, `PrivacyInfo.xcprivacy` |
| Sandbox | Entitlements: app sandbox, network client, user-selected files read/write — nothing else | `Config/InvestiQ.entitlements` |
| Logging | No `print`/`NSLog`/`os_log` of amounts, holdings, keys or URLs with queries (none present) | code search |

## Findings of this review

| # | Finding | Severity | Status |
|---|---|---|---|
| S1 | `try?` on user-data paths hid failures (ledger hash, value series, CSV export, performance chart, editor loading, file import, settings saves) | Medium (integrity/visibility) | **Fixed** — errors are now shown |
| S2 | Backup files could declare huge Argon2id parameters (memory exhaustion on restore) | Medium (DoS) | **Fixed** — bounds checked before derivation |
| S3 | Different POST bodies could have been merged by request de-duplication | Low | **Fixed** — body hash in dedup key |
| S4 | Notification texts may appear on the lock screen | Low (privacy) | Mitigated — names and percentages only, never amounts; documented in Settings |
| S5 | Decrypted database lives in process memory while unlocked | Inherent | Accepted — auto-lock on sleep, screen lock and inactivity; on lock the session and its in-memory database are released (memory is not explicitly zeroed) |
| S6 | Restore keeps one previous generation; older generations are not retained | Low | Accepted — the user is told to keep backup files |
| S7 | `LoginThrottle` state that cannot be decoded is treated as a fresh state | Low | Accepted — the state lives in the Keychain, which an attacker with write access already controls |

No known critical or high-severity issues remain open.

## Dependencies

| Dependency | Version | Use | Review notes |
|---|---|---|---|
| swift-sodium | 0.12.0 (exact) | Argon2id | Maintained by the libsodium author; prebuilt xcframework on Apple platforms |
| libsodium | 1.0.22 (Linux CI, from the upstream tag) | Argon2id on Linux | Built from source in `ci/Dockerfile.linux` |
| swift-crypto | 3.x–5.x (resolved 5.2.0), **Linux only** | AES-GCM/HKDF/SHA-256 on Linux | Apple platforms use CryptoKit |

## Required before release

1. Independent security review / penetration test of the signed build.
2. Verify Data Protection Keychain + Touch ID with the production team ID and bundle ID.
3. Run the app with the Hardened Runtime and sandbox under `codesign --verify --strict` and `spctl`.
4. Review third-party provider terms for local caching (see LEGAL_AND_LICENSING_REVIEW.md).

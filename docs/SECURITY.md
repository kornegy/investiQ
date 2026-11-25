# InvestiQ — Security Design

Status: v1 (Phase 0). Threats are analysed in `THREAT_MODEL.md`. Results of reviews are in
`reports/SECURITY_REPORT.md`. **No custom cryptographic algorithms are implemented**; only vetted
primitives are composed.

## 1. Principles

* Local-first, least data, least privilege, secure by default.
* Defence in depth: OS protections (App Sandbox, Hardened Runtime, FileVault, Keychain) **plus**
  application-level encryption of the user's financial data.
* Fail closed: decryption/authentication failures never fall back to plaintext or defaults.
* No telemetry, no analytics SDKs, no crash reporters that upload data.

## 2. Cryptographic building blocks

| Purpose | Primitive | Implementation |
|---|---|---|
| Data encryption | AES-256-GCM (96-bit random nonce, 128-bit tag, AAD = file header) | CryptoKit (Apple), swift-crypto (Linux tests) |
| Password → key | **Argon2id** (libsodium `crypto_pwhash`, alg `ARGON2ID13`), 32-byte output, 16-byte random salt | swift-sodium 0.12.0 (libsodium 1.0.22) |
| Sub-key derivation | HKDF-SHA256 (distinct `info` labels per purpose) | CryptoKit / swift-crypto |
| Random | System CSPRNG (`SystemRandomNumberGenerator` / `SecRandomCopyBytes` via CryptoKit `SymmetricKey(size:)`) | OS |
| Integrity of fixtures/content | SHA-256 | CryptoKit / swift-crypto |

Argon2id parameters (v1): `opslimit = 3`, `memlimit = 64 MiB` (OWASP minimum is 19 MiB / t=2). They
are stored in the key envelope so they can be raised later without breaking existing profiles
(re-wrapping on the next successful unlock).

## 3. Key hierarchy and encryption at rest

```text
password ──Argon2id(salt, params)──▶ KEK (32 B, memory only)
                                        │ AES-GCM unwrap
Keychain: KeyEnvelope{v, profileID, kdf, salt, wrappedDEK} ──▶ DEK (32 B, memory only while unlocked)
                                        │ HKDF(info)
              ┌─────────────────────────┼──────────────────────────┐
     "investiq.userdb.v1"      "investiq.cachedb.v1"        "investiq.prefs.v1"
     user.iqdb key              cache.iqdb key               (reserved)
```

* **DEK** (data-encryption key): 256 random bits generated at profile creation. Never written to disk
  in plaintext.
* **KeyEnvelope**: DEK wrapped with the KEK using AES-GCM; AAD binds it to the profile ID and envelope
  version. Stored as a Keychain generic-password item (`service = <bundle-id>.key-envelope`,
  `account = profileID`). A wrong password fails GCM authentication — there is no separate password
  hash to steal.
* **Touch ID**: when enabled, a second copy of the DEK is stored in the **Data Protection Keychain**
  with `SecAccessControl(kSecAccessControlBiometryCurrentSet)` and
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The OS (Secure Enclave-backed) releases it only after
  a successful biometric check. Enrolling a new fingerprint invalidates the item (password required).
  The app never sees biometric data. If the build lacks the required entitlement
  (`errSecMissingEntitlement`, typical for ad-hoc signed builds) Touch ID is reported as unavailable —
  it never silently falls back to a weaker scheme.
* **Database files**: in-memory SQLite databases are serialised, encrypted (AES-256-GCM) and written
  atomically. File format `IQDB` v1:

  | Offset | Size | Field |
  |---|---|---|
  | 0 | 4 | magic `IQDB` |
  | 4 | 2 | format version (big-endian, 1) |
  | 6 | 2 | content kind (1 = user, 2 = cache) |
  | 8 | 16 | profile UUID |
  | 24 | 8 | schema version |
  | 32 | 12 | nonce |
  | 44 | n | ciphertext ‖ 16-byte tag (AAD = bytes 0…43) |

  Rationale and alternatives (SQLCipher, per-field encryption, SwiftData) are in ADR-003. The system
  SQLite library is **not** assumed to provide encryption.
* **Password change**: unwrap DEK with old KEK → new salt → wrap with new KEK → replace envelope
  atomically. Data files are not re-encrypted (the DEK is unchanged).
* **Profile deletion**: delete envelope + biometric item (crypto-shredding), then delete files.
  Because SSD/APFS overwriting is not reliable, crypto-shredding is the actual guarantee.
* **Memory**: keys are held in `SymmetricKey` (zeroised on deallocation on Apple platforms). Swift
  cannot guarantee zeroisation of all transient copies; the session object is released on lock.

## 4. Authentication and session

* Password policy: ≥ 10 characters, not all identical characters, not in a small embedded list of the
  most common passwords, confirmation required; strength meter is advisory.
* **Rate limiting** (`LoginThrottle`): 5 free attempts, then lockout of 30 s, doubling per further
  failure, capped at 15 min. State persisted in the Keychain (`<bundle-id>.auth-throttle`) so it
  survives restarts; monotonic clock used in-process; wall-clock rollback is detected and treated as
  "still locked". Honest limitation: an attacker with file/Keychain access can attack the envelope
  offline; Argon2id cost is the real defence there.
* Auto-lock: inactivity timer (default 5 min), `NSWorkspace.willSleepNotification`,
  `com.apple.screenIsLocked` distributed notification, manual ⌘L. Locking drops the session.
* No "remember password". No password hints.

## 5. Secrets

* API keys are stored only in the Keychain (`service = <bundle-id>.api-key`, `account = providerID`),
  never in the database, `UserDefaults`, logs, backups or exports.
* Keys are injected into requests by the provider adapter at the last moment; request descriptions used
  for caching/de-duplication/logging use a redacted URL (`Redactor` strips `apikey`, `api_key`,
  `token`, `key`, `apiKey` query items and `Authorization` headers).
* No secret is committed to Git (`.gitignore`, CI secret scanning recommended).

## 6. Network security

* HTTPS only. App Transport Security left at defaults (no `NSAllowsArbitraryLoads`); provider base
  URLs are compile-time constants validated to be `https`.
* TLS certificate validation is never disabled; no custom `URLSessionDelegate` trust overrides.
* Ephemeral `URLSessionConfiguration` (no cookies, no URL cache — the app keeps its own encrypted cache).
* Response size limits (default 10 MB, 25 MB for bulk EDGAR JSON), JSON depth/time limits via
  decoding into typed DTOs, timeouts (15 s request / 60 s resource).
* All provider data is validated (`DataValidator`): finite numbers, plausible ranges, currency codes,
  monotonic timestamps, no future market timestamps, OHLC consistency (low ≤ open/close ≤ high).

## 7. Untrusted content

* News text, RSS, provider descriptions and AI output are **data**: rendered as plain text, never as
  HTML/Markdown with active content, never executed, never used to build file paths or commands.
* External links: only `https` (and `http` with a warning) are allowed; before opening, the app shows
  the **real destination host** (punycode-decoded with mixed-script warning) and opens it in the
  default browser only after confirmation. The app never downloads or launches third-party
  applications.
* CSV import: strict parsing with size and row limits; values are typed and validated.
  CSV export: cells starting with `=`, `+`, `-`, `@`, tab or carriage return are prefixed with `'`
  (OWASP CSV-injection guidance) unless they are plain numbers.

## 8. Logging

`os.Logger` (Apple) with privacy: dynamic values default to `.private`. No financial amounts, holdings,
passwords, keys or full URLs with query strings are logged. Logs never leave the device.

## 9. Platform hardening (app target)

* App Sandbox: `com.apple.security.app-sandbox`, `com.apple.security.network.client`,
  `com.apple.security.files.user-selected.read-write` (for backup/export/import only). No other
  entitlements.
* Hardened Runtime enabled; no JIT, no unsigned executable memory, no DYLD environment variables, no
  disabled library validation.
* No background daemons/launch agents. Notifications are local.

## 10. Dependencies

| Dependency | Version | Purpose | Notes |
|---|---|---|---|
| swift-sodium | 0.12.0 (exact) | Argon2id via libsodium | Maintained by libsodium's author; macOS uses the bundled `Clibsodium.xcframework`; Linux CI builds libsodium 1.0.22 from the upstream tag |
| swift-crypto | 3.x–5.x | CryptoKit API on Linux only | Not linked on Apple platforms (platform-conditional dependency) |

Audit process: pin versions (`Package.resolved` committed), review changelogs before upgrades,
check GitHub security advisories, no transitive dependency added without an ADR.

## 11. AI security

See `ARCHITECTURE.md` and FR-AI: consent, minimisation, delimited untrusted content, schema-validated
output, no tools, no write access, no secrets in prompts.

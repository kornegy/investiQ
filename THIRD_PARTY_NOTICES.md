# Third-party notices

InvestiQ uses the following open-source components. Full licence texts are distributed with each
component (see the linked repositories) and must be included in an in-app acknowledgements screen before
release (docs/reports/APP_STORE_CHECKLIST.md).

| Component | Version | Licence | Used for | Platforms |
|---|---|---|---|---|
| [swift-sodium](https://github.com/jedisct1/swift-sodium) | 0.12.0 | ISC | Swift bindings to libsodium (Argon2id) | macOS, Linux |
| [libsodium](https://github.com/jedisct1/libsodium) | 1.0.22 (Linux CI); bundled xcframework on Apple platforms | ISC | Argon2id password hashing / key derivation | macOS, Linux |
| [swift-crypto](https://github.com/apple/swift-crypto) | 5.2.0 (resolved) | Apache-2.0 | AES-GCM, HKDF, SHA-256 on Linux (CryptoKit is used on Apple platforms) | Linux only (tests/CI) |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.5 (resolved, dependency of swift-crypto) | Apache-2.0 | — | Linux only |

System frameworks (CryptoKit, SwiftUI, Swift Charts, LocalAuthentication, Security, UserNotifications,
FoundationModels) are part of macOS.

Data and content sources are listed in `docs/DATA_PROVIDERS.md`; bundled calendar and broker facts cite
their sources per entry.

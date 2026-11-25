# Release configuration, code signing and sandbox verification

## Current configuration
* Xcode project `InvestiQ.xcodeproj` (objectVersion 77, file-system synchronised groups), scheme
  `InvestiQ` with UI tests, Swift 6 language mode, strict concurrency, deployment target macOS 14.0.
* Signing: "Sign to Run Locally" (`CODE_SIGN_IDENTITY = "-"`), placeholder bundle ID
  `com.example.InvestiQ`, Hardened Runtime on, App Sandbox on.
* Entitlements (`Config/InvestiQ.entitlements`): `app-sandbox`, `network.client`,
  `files.user-selected.read-write`. Nothing else (no camera, contacts, location, downloads folder,
  network server, JIT, unsigned memory, library validation exceptions).
* Debug-only UI-testing environment (`--ui-testing`) uses a temporary directory and an in-memory
  keychain; it is compiled out of Release builds (`#if DEBUG`).

## Steps for a signed release
1. Set the Development Team and the production bundle identifier.
2. Product → Archive (Release). Validate the archive in Organizer.
3. Verify:
   ```bash
   codesign --verify --deep --strict --verbose=2 InvestiQ.app
   codesign -d --entitlements - InvestiQ.app
   ```
   Confirm the entitlements match the list above and the Hardened Runtime flag is set.
4. Mac App Store: upload through Organizer. Direct distribution: `xcrun notarytool submit … --wait`,
   then `xcrun stapler staple InvestiQ.app` and `spctl --assess --type execute -vv InvestiQ.app`.
5. On a clean Mac: launch, create a profile, enable Touch ID (needs the signed build), quit, relaunch,
   unlock, restore a backup made by the previous version (data migration check).

## Sandbox verification checklist
- [ ] App writes only to its container (`~/Library/Containers/<bundle id>/Data/Library/Application Support/InvestiQ`).
- [ ] File import/export/backup work only through the system open/save panels.
- [ ] Network: only the hosts of enabled providers (check with Little Snitch or `nettop`); no network
      traffic at all in demo mode.
- [ ] Keychain items are created per profile and removed when the profile is deleted.
- [ ] Notifications permission prompt appears only after the user clicks "Allow notifications".

## Data migration testing
* Schema migrations are tested in `SQLiteAndSchemaTests` (v1 → v2 in place, idempotence, refusal of
  newer databases) and on restore of older backups (`BackupTests`). Before each release, add a test for
  every new migration and restore a backup from the previous release on a real Mac.

# Changelog

## 1.0

First release.

- **Lookup**
  - App Store search across iPhone, iPad and Mac, with storefront presets; results for the same app on several platforms are merged into one record. App details come from the App Store's MDM lookup when it is available.
  - Apple built-in apps from Apple's published list (75 apps, 53 of them built in).
  - Local Mac apps from `/Applications`, `/System/Applications`, `/System/Cryptexes/App/System/Applications`, optionally `~/Applications`, or a dropped bundle: CDHash, TeamID, SigningID, PathPrefix and SigningState per architecture slice, and the composed `Bundle-ID {Designated-Requirement}` identifier.
- **Rule set**
  - Apps, Binaries and Privacy: Permission Defaults tabs, validated as you edit, with a live JSON preview.
  - A macOS rule set is written as up to two declarations — SYSTEM for binaries, USER for Privacy — as Apple's channel rules require.
  - Warns when a macOS allow list lacks `AlwaysAllowManagedApps` or the Apple-signed baseline.
  - Save and open rule sets as JSON; import and export App Settings Utility's two CSV formats.
  - Undo and redo.
- **Jamf**
  - Connect to the Jamf Platform API (US, EU, APAC) with OAuth client credentials; multiple connections, secrets in the keychain.
  - List Blueprints, show the App Settings they contain and load one into the editor.
  - Write to a new Blueprint (with device-group scope and an optional activation predicate) or to an existing one: concurrency check, backup, diff review, PATCH of the full `steps` array, and read-back verification.
  - Restore any backup.
  - Deploy after an explicit confirmation listing the device groups and device count, then follow the deployment until it finishes.
  - Request log with secrets redacted.
- **App**
  - About window with Acknowledgements for App Settings Utility by Anthony Darlow.
  - Daily update check against GitHub releases, which can be turned off.

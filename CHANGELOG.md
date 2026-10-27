# Changelog

## Unreleased

- About and Acknowledgements now come from JTKit, shared with Jordy's other apps. About opens only from the app menu and is no longer listed in the Window menu.
- **Demo Mode**: try the app without a Jamf tenant. Turn it on in the connection picker or the Connection menu (or with **Try Demo Mode** when no connection is set up). It shows a sample organisation's Blueprints and device groups; writes, scope changes, restores and deployments work on the sample data only, and nothing is sent to Jamf. Window titles end in "— Demo" while it's on. Backups made in Demo Mode go to a temporary folder, and your saved connections and Keychain items are never touched. App Store lookups and local app scans still work as usual.
- The "Check for updates daily" switch moved from About to **Settings › Updates**; your choice is kept. **Check for Updates…** stays in the app menu.

## 1.1

- **Edit Scope** for Jamf Pro: change an existing Blueprint's device groups. Only the scope is sent, after a concurrency check and a backup, and the read-back is verified. Removing groups from a deployed Blueprint needs an extra confirmation. Also the way to scope an unscoped Blueprint before writing to it.
- **Jamf School**: recognised automatically. Writing to existing Blueprints and deploying work as with Jamf Pro; because the Platform API does not list Jamf School device groups, new Blueprints and scope changes are left to Jamf School, and the deploy confirmation shows group IDs.
- **Shared iPad**: an iOS rule set can be written to the user channel, as Apple requires on Shared iPad. Loading such a declaration from a Blueprint turns the option on.
- The Blueprint header shows the scope.

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

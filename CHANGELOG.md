# Changelog

## 1.3.0

- **Waiting for Jamf is shown**: when Jamf asks the app to wait before trying again, the write, scope, restore and deploy sheets say how long, with **Stop**. A wait lasts at most 60 seconds.
- A Keychain that is locked or refuses access is now reported as such, instead of as an incomplete connection.
- **Use This Connection** in **Settings › Connections** now leaves Demo Mode, as the connection picker and the Connection menu do.
- After switching the connection or Demo Mode, the editor’s rule set is no longer linked to a Blueprint of the previous connection.
- Write to Jamf: a Blueprint whose details can’t be loaded shows the error with **Try Again**, instead of “Loading the Blueprint…”.
- Blueprints without a last-modified time (some made in the Jamf UI) are no longer reported as changed in Jamf when only their deployment state changed.
- Changing a saved connection’s region keeps its stored client secret, so **Test Connection** and **Load Environments** work without typing it again.
- The review diff in Write to Jamf shows each line in full again; long lines scroll sideways.
- **Menu commands and shortcuts**: the File menu has New macOS Rule Set (⌘N), New iOS / iPadOS Rule Set (⌥⌘N), Open Rule Set… (⌘O), Save Rule Set… (⌘S) and Import CSV… (⇧⌘I). A new Blueprint menu has Write to Jamf… (⇧⌘J), Reload Blueprint (⌥⌘R), Edit Scope…, Backups… and Deploy… (⇧⌘D) for the selected Blueprint.
- The window title shows the section you’re in, such as Editor or Blueprints.
- The Write to Jamf, Edit Scope and Restore from Backup sheets can be resized.
- Copy buttons confirm with “Copied”. Error messages in the status bars and the warning about denying Apple’s own apps, the App Store among them, are easier to read.
- Switching the connection or Demo Mode from the Connection menu or Settings now also clears the previous connection’s Blueprints while the main window is closed. Renaming the connection in use keeps the editor’s link to its Blueprint.
- A write, scope change, restore or deployment that finishes after you switched connections is shown in its sheet only, and isn’t added to the new connection’s Blueprints.
- When you stop waiting for Jamf during a write, the sheet says you stopped it and offers only Close.
- Edit Scope checks that nobody changed the scope in Jamf since the sheet opened. After “changed in Jamf”, Back starts from the Blueprint as it is now.
- Stop in a sheet ends only that sheet’s wait.

## 1.2.0 (2026-10-31)

- **Demo Mode**: try the app without a Jamf tenant. Turn it on in the connection picker or the Connection menu (or with **Try Demo Mode** when no connection is set up). It shows a sample organization’s Blueprints and device groups; writes, scope changes, restores and deployments work on the sample data only, and nothing is sent to Jamf. Window titles end in “— Demo” while it’s on. Backups made in Demo Mode go to a temporary folder, and your saved connections and Keychain items are never touched. App Store lookups and local app scans still work as usual.
- **Load Environments** in **Settings › Connections** lists the environments an organization-scoped integration can see, so you can pick the Environment ID instead of copying it.
- **Quitting with unsaved changes** now asks whether to save the rule set first (Save…, Don’t Save, Cancel).
- **Deploy checks the Blueprint once more** just before deploying. If its scope or steps changed in Jamf since the confirmation opened, nothing is deployed and the confirmation is shown again with the new state.
- **Writes that may have reached Jamf** are no longer shown as “Nothing Was Written”. When Jamf accepted a write but reading it back failed, or didn’t answer clearly, the sheet says so and offers only Close, so a Blueprint can’t be created twice by accident.
- **Return no longer creates a Blueprint** or changes a scope: in Write to Jamf’s New Blueprint and in Edit Scope, click the button. Return still opens Review Changes… for an existing Blueprint.
- Write to Jamf opens on **Existing Blueprint** until the Blueprint list is known to be empty. A Blueprint whose details can’t be loaded says so, with **Try Again**, instead of staying on “Loading…”.
- Removing groups in **Edit Scope** also asks for the extra confirmation when the Blueprint’s deployment state is unknown.
- The second deploy confirmation for a macOS allow list without the recommended baseline now also covers App Settings in components the app doesn’t edit.
- Sheets refuse to send anything when the connection was switched while they were open.
- **Backups**: **Settings › General** explains what backups contain and has a **Keep backups** choice (Forever, 1 Year, 90 Days, 30 Days; Forever is the default). The newest backup of each Blueprint is always kept. Backup files and folders are now readable only by your user account.
- The review diff of a large allow list is computed once, off the main thread, instead of on every redraw.
- **View › Fetch Blueprint by ID…**: the toolbar’s Fetch by ID is now also in the menu bar.
- Results, warnings and errors keep their colored symbol but show their text in the normal text color, which is easier to read than orange or green text.
- About is in the app menu only; it’s no longer listed in the Window menu.
- The “Check for updates daily” switch moved from About to **Settings › Updates**; your choice is kept. **Check for Updates…** stays in the app menu.
- Text: American English throughout, “Blueprint” capitalized, “Try Again” and “Show in Finder” everywhere, and dates such as the built-in apps list’s shown as “September 11, 2026”.
- Fixed: **Write to Jamf…** opened before the Blueprints list had loaded (for example, right after launch) showed every Blueprint as “Loading…”, so none could be chosen. Their details now load as soon as the list arrives.

## 1.1

- **Edit Scope** for Jamf Pro: change an existing Blueprint's device groups. Only the scope is sent, after a concurrency check and a backup, and the read-back is verified. Removing groups from a deployed Blueprint needs an extra confirmation. Also the way to scope an unscoped Blueprint before writing to it.
- **Jamf School**: recognized automatically. Writing to existing Blueprints and deploying work as with Jamf Pro; because the Platform API does not list Jamf School device groups, new Blueprints and scope changes are left to Jamf School, and the deploy confirmation shows group IDs.
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
  - Connect to the Jamf Platform API (US, EU, APAC) with OAuth client credentials; multiple connections, secrets in the Keychain.
  - List Blueprints, show the App Settings they contain and load one into the editor.
  - Write to a new Blueprint (with device-group scope and an optional activation predicate) or to an existing one: concurrency check, backup, diff review, PATCH of the full `steps` array, and read-back verification.
  - Restore any backup.
  - Deploy after an explicit confirmation listing the device groups and device count, then follow the deployment until it finishes.
  - Activity log with secrets redacted.
- **App**
  - About window with Acknowledgements for App Settings Utility by Anthony Darlow.
  - Daily update check against GitHub releases, which can be turned off.

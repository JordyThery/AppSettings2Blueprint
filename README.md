<p align="center">
  <img src="docs/icon.png" width="128" alt="AppSettings2Blueprint app icon">
</p>

# AppSettings2Blueprint

*Find app identifiers, build App Settings rules and deploy them as a Jamf Blueprint.*

[![Latest release](https://img.shields.io/github/v/release/JordyThery/AppSettings2Blueprint?label=release)](https://github.com/JordyThery/AppSettings2Blueprint/releases/latest)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Credits

Identifier discovery is based on Anthony Darlow's **App Settings Utility**:

- Repository: [cantscript/AppSettingsUtility](https://github.com/cantscript/AppSettingsUtility)
- Blog post: [Stop Hunting for Bundle IDs & CDHashes](https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/)

The App Store endpoints, the SigningState requirement strings, the composed-identifier format, the scan folders, the CSV columns and the embedded Apple app list all come from his script. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists what was ported and carries his MIT licence, which is also shown in **About AppSettings2Blueprint → Acknowledgements**.

## What it does

Apple's `com.apple.configuration.app.settings` declaration (iOS, iPadOS, macOS, tvOS and visionOS 27 and later) allows and denies apps, allows and denies Mac binaries, and sets privacy permission defaults. Writing one takes Bundle IDs, CDHashes, Team IDs, signing IDs and designated requirements, collected from several places. AppSettings2Blueprint brings that work into one app:

1. **Find identifiers**
   - App Store apps: Bundle IDs, for AllowedApps and DeniedApps.
   - Apple built-in apps: Bundle IDs, from Apple's published list.
   - Local Mac apps: CDHash, TeamID, SigningID, PathPrefix and SigningState for each architecture slice, for AllowedBinaries and DeniedBinaries, plus the composed `Bundle-ID {Designated-Requirement}` identifier for Privacy.PermissionDefaults.
2. **Build rules** in a validated editor with a live JSON preview. Save rule sets locally and import or export App Settings Utility's CSV files.
3. **Write to Jamf**: create a new Blueprint or update an existing one through the Jamf Platform API, then deploy it after an explicit confirmation.

It is not a policy advisor. It shows what each identifier matches; you decide what to allow or deny.

## Installation

Download the latest notarized build from [Releases](https://github.com/JordyThery/AppSettings2Blueprint/releases/latest), unzip it, and move **AppSettings2Blueprint.app** to `/Applications`. Requires **macOS 15 or later**. The app checks for new releases once a day and offers the download; use **Check for Updates…** in the app menu to check right away.

## Permissions

In [Jamf Account](https://account.jamf.com), create an API integration scoped to the **platform environment** and grant it:

| Capability | Actions | Needed for |
| --- | --- | --- |
| `blueprints` | Read | Listing Blueprints, loading their App Settings, verifying writes and following deployments |
| `blueprints` | Create | Writing a rule set to a new Blueprint |
| `blueprints` | Update | Writing a rule set to an existing Blueprint, and restoring a backup |
| `blueprints` | Deploy | Deploying a Blueprint |
| `device-groups` | Read | Choosing the scope of a new Blueprint, and showing group names and device counts before a deploy |

The Lookup section needs no Jamf permissions at all. Reading local apps needs no macOS privacy permission either: the app is not sandboxed and reads `/Applications`, `/System/Applications`, `/System/Cryptexes/App/System/Applications` (Safari's location), optionally `~/Applications`, and any app you drop on it.

## Getting started

1. Open **Settings** (⌘,), add a connection, enter the region, **Environment ID**, **Client ID** and **Client Secret**, and click **Test Connection**. The API has no endpoint to look up the Environment ID, so you enter it yourself.
2. Collect identifiers under **Lookup** and add them to the rule set.
3. Build the rules under **Rule Set**: the "iOS / iPadOS: Apps", "macOS: Binaries" and "Privacy: Permission Defaults" tabs. The JSON preview shows the declarations that will be written.
4. Click **Write to Jamf…**, choose a new or an existing Blueprint, review the diff and write it.
5. Deploy from the write sheet or from **Jamf → Blueprints → Deploy…**.

On macOS, Apple only accepts the binary rules in the system channel and Privacy in the user channel, so a macOS rule set is written as up to two declarations in the same component: a SYSTEM declaration with the binaries and a USER declaration with the permission defaults. A rule set that uses only one side gets only that declaration.

## Saving safely

The Blueprints API applies updates as a JSON merge-patch, which replaces arrays wholesale. A careless write could therefore delete parts of a Blueprint. The app guards against this:

- **Nothing outside the App Settings component changes.** Every write sends the complete `steps` array, with every other step and component exactly as it was received: key order and number formatting are preserved, not re-canonicalised.
- **Concurrent changes are caught.** The Blueprint is fetched again before the review and once more just before the PATCH. If it changed on the server, nothing is written.
- **Every write is backed up first.** The full Blueprint is written to `~/Library/Application Support/AppSettings2Blueprint/Backups/<blueprint ID>/`, and **Backups…** puts a backup's steps back. Backups are never overwritten.
- **Every write is verified.** The app reads the Blueprint back and compares the App Settings component and every other component with what it sent.
- **Division-locked Blueprints are left alone.** `divisionId` is never sent, and Blueprints assigned to a division are read-only.
- **Writing never deploys.** Deploying needs a confirmation that shows the Blueprint, its device groups and the device count. A macOS allow list without `AlwaysAllowManagedApps` or the Apple-signed baseline needs a second confirmation.
- **The HTTP layer refuses everything else.** Only GET, `POST /auth/token`, `POST /blueprints` (create), `PATCH /blueprints/{id}` and `POST /blueprints/{id}/deploy` reach the network. There is no DELETE and no undeploy anywhere in the app. Deploy is retried on 429 only.

## Network

The app contacts only these hosts:

| Host | When | What is sent |
| --- | --- | --- |
| `{region}.api.jamfcloud.com` | Jamf sections, and Test Connection | Your connection's credentials and the Blueprint requests above |
| `itunes.apple.com` | App Store search | The search term, storefront and platform |
| `uclient-api.itunes.apple.com` | App Store app details | The App Store ID and storefront |
| `is1`–`is5-ssl.mzstatic.com` | App Store search results | Requests for app icons, from the URLs Apple returns |
| `api.github.com` | Once a day, and on **Check for Updates…** | A request for the latest release. Turn the daily check off in **About** |
| `github.com`, `objects.githubusercontent.com` | Only when you click **Download** in the update sheet | A request for the release zip |

Lookups never include Jamf data or credentials.

## Security

- **Credentials** stay on your Mac. Client secrets are stored in the keychain; the other connection settings are stored in user defaults.
- **Request log**: kept in memory only, with tokens and secrets redacted.
- **Backups** contain the Blueprint's JSON and no credentials. They are stored unencrypted in your user Library.
- **No sandbox**: the app is not sandboxed so it can read apps anywhere on disk. It runs with the Hardened Runtime and is signed with a Developer ID and notarized.

## Known limitations

- **A Blueprint needs a scope before it can be changed.** The Platform API rejects a PATCH to a Blueprint without device groups (400 NotBlank: scopeId), even one that only sends steps. The app refuses such writes before backing up or sending anything; add a device group in Jamf first.
- **Not Deployed versus Out of Date.** After a write, a Blueprint that has never been deployed stays *Not Deployed*. *Out of Date* only appears for a Blueprint that has been deployed before.
- **Embedded helpers are not inspected.** The local scan stops at the first `.app` bundle, as App Settings Utility does, so helpers, XPC services and login items inside an app are not listed. Drop them on the app to inspect them one by one.
- **Shared iPad is not supported.** On Shared iPad the declaration uses the USER channel; the app writes iOS and iPadOS rule sets to the SYSTEM channel only.
- **Undo is per keystroke** in text fields.
- **The App Store detail endpoint is undocumented.** `uclient-api.itunes.apple.com` may change without notice. Search still works without it; only the extra details are missing.
- **The Blueprints API is in beta.** Its behaviour can change; the app's verification step reports any difference between what it sent and what the server returned.

## Building

Open `AppSettings2Blueprint.xcodeproj` in Xcode 27 or later and build the `AppSettings2Blueprint` scheme (⌘R). The app has no dependencies and uses only Apple frameworks.

- **Unit tests** (Swift Testing): ⌘U, or the `AppSettings2Blueprint` scheme's test action.
- **UI tests** (XCUITest): `Scripts/run-ui-tests.sh`. It builds into a throwaway DerivedData folder, writes the UI hierarchy of a failing test to `/tmp/as2b-uidump.txt`, and exports the run's screenshots to `/tmp/as2b-uitest-attachments`.

## Support

If AppSettings2Blueprint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE). Material ported from App Settings Utility is covered by its own MIT licence; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

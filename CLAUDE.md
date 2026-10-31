# AppSettings2Blueprint: instructions for Claude

At the start of every conversation, run ../JTKit/Scripts/check-versions.sh (or fetch it from GitHub if ../JTKit isn’t there) and mention the result in one line if anything is out of date.

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app does

A macOS app for Mac admins who use Jamf. It finds app identifiers (App Store, Apple built-in apps, local Mac apps), builds Apple's `com.apple.configuration.app.settings` (DDM) rules in a validated editor, and writes them to a Jamf Blueprint through the Jamf Platform API, then deploys after confirmation. Identifier discovery is based on Anthony Darlow's App Settings Utility (MIT); keep that credit in README.md, THIRD-PARTY-NOTICES.md and About › Acknowledgements.

It is not a policy advisor: it shows what each identifier matches; the admin decides what to allow or deny.

## How to work on it

- App-only work: open `AppSettings2Blueprint.xcodeproj`. Its notes load there and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Build releases from the app's own project. Never have the app open in both the project and the workspace.
- Commit only when Jordy asks (he approves each milestone). After merging into main, push main to origin straight away (keep GitHub in sync). Before pushing, check the new commits contain no credentials, Environment IDs, tenant names or screenshots. The repo is public; `.gitignore` ignores PNGs in the repo root because they are often credential screenshots. README images go in `docs/`.

## Architecture

- `App/`: `AppModel` (active connection, Blueprint list, device groups, Jamf School detection), `RuleSetDocument` (the rule set, undo), `JamfWriteModel`, `DeployModel`, `EditScopeModel`, `AppStoreModel`, `LocalAppsModel`, `AboutInfo` (About and the App Settings Utility acknowledgement).
- `Rules/`: `RuleSet`, `BinaryRule`, `PermissionDefault`, `RuleValidator`, `DeclarationEncoder` / `DeclarationDecoder` (rule set to and from declarations).
- `Blueprints/`: `AppSettingsLocator` (finds and replaces the App Settings component), `BlueprintWriter` (prepare, back up, write, verify, restore), `BackupStore`.
- `Lookup/`: `AppStoreClient`, `CodeSignatureInspector`, `MachOSlices`, `LocalAppScanner`, `AppleBuiltInApps` (with `Resources/AppleBuiltInApps.json`).
- `Interop/`: App Settings Utility's two CSV formats, import and export.
- `API/`: `RequestAllowList` and `PlatformAPIClient` (builds JTKit's client with the app's allow-list and hint); `APIError`.
- `Connection/`: `ConnectionProfile`, `ProfileStore` (on JTKit's `ConnectionStore`).
- `Core/TextDiff` (review diff), `Views/` (SwiftUI).

From JTKit: `JamfPlatform` (client, Blueprints list/get/create/PATCH steps/PATCH scope/deploy/report, device groups, deploy watch, error format, `PermissionProblem`, environments), `LosslessJSON`, `JamfRegion`, `RequestRecorder` + `ActivityLog` + `ActivityLogWindow`, `ConnectionStore` + `KeychainSecretStore` + `ConnectionsSettingsTab` + `ConnectionPicker` + `ConnectionCommands`, `AboutWindow` + `Acknowledgement`, `SettingsWindow`, `UpdateChecker` + `AppInfoCommands`. Tests use `JTKitTestSupport`.

App-specific (stays here): declaration encoding/decoding, rules and validation, `AppSettingsLocator`, `BlueprintWriter`, `BackupStore`, CSV, App Store and code-signature lookups, the allow-list, Jamf School detection.

Extend JTKit instead of adding another copy. If something here would be useful to another app, it belongs in JTKit (via the workspace).

**Stored data, never rename:** UserDefaults `connectionProfiles` and `selectedConnectionProfileID`; `ConnectionProfile` field names; region values `us`/`eu`/`apac`; Keychain service `AppSettings2Blueprint.client-secret`, account = profile UUID; backups in `~/Library/Application Support/AppSettings2Blueprint/Backups/<blueprint ID>/`.

## Writing to Blueprints: rules

- The Blueprints API applies PATCH as a JSON merge-patch, which replaces arrays wholesale. Always send the complete `steps` array, with everything outside the App Settings component exactly as received (`LosslessJSON` keeps key order and number text). Never reformat or re-sort JSON.
- Only the `com.jamf.ddm-strict` component is edited. App Settings in other components are shown, not changed.
- Order of a write: fetch again, check `updated` and the steps are unchanged, back up, PATCH, verify against a read-back. If the Blueprint changed on the server, write nothing.
- Backups are never overwritten. Write them with `.withoutOverwriting` only, never combined with `.atomic`.
- Never send `divisionId`. Division-assigned Blueprints are read-only (JTKit's `DIVISION_PATCH_NOT_ALLOWED`).
- The allow-list permits only GET, `POST /auth/token`, Blueprint create, PATCH and deploy. Never add DELETE or undeploy.
- Writing never deploys. Deploy needs a confirmation listing groups and device count, and a second one for a macOS allow list without `AlwaysAllowManagedApps` or the Apple-signed baseline. Removing groups from a deployed Blueprint needs an extra confirmation.
- Edit Scope sends only the scope, after the same checks and backup, and verifies the steps are unchanged.

## Verified Jamf behaviour

- The Jamf UI writes App Settings as component `com.jamf.ddm-strict`, channelType `SYSTEM`, with declaration members in the order `kind, type, payload, channelType`. An empty component has `payload: {}`. New declarations follow the same order.
- A Blueprint created in the Jamf UI can have `scope: null` and `description: null`, even though POST requires at least one device group.
- PATCH of `steps` on a Blueprint with `scope: null` fails with 400 NotBlank (field `scopeId`). The app refuses before backup or PATCH (`BlueprintWriter.WriteError.noScope`). A scope-only PATCH `{"scope":{"deviceGroups":[…]}}` on such a Blueprint succeeds (204); after that, steps PATCHes work.
- Any scope change to a deployed Blueprint makes it Out of Date. After a write, a never-deployed Blueprint stays Not Deployed.
- PATCH of `name` or `description` returns 204 and does not change the deployment state. A name over 200 characters gives 400 Size; an empty or null name is accepted although the spec says minLength 1. (From notes; the app doesn't rename yet.)
- **Jamf School** environments work through the same Platform API: list, detail, create, PATCH steps and deploy (202, then PENDING, then SUCCEEDED) all behave as on Jamf Pro, and App Settings read back identically. School's own components are `com.jamf.ddm.*` with Jamf-specific `configuration` objects, no `declarations`. School device group IDs are numeric strings, not UUIDs. The device-groups list returns 404 `TENANT_NOT_FOUND`; that is how the app detects School (`AppModel.isJamfSchool`).

## Apple's channel rules (from Apple's app.settings schema)

- macOS: `AllowedBinaries`, `DeniedBinaries` and `AlwaysAllowManagedApps` are system-channel only; `Privacy` is user-channel only. iOS: system channel; Shared iPad: user channel.
- `apply: combined`: Allowed* lists intersect, Denied* lists union, `AlwaysAllowManagedApps` is a boolean OR, enums take the last value.
- Decided by Jordy: a macOS rule set is written as a SYSTEM declaration (binaries) and a USER declaration (Privacy), SYSTEM first, both in the same `com.jamf.ddm-strict` component. The Shared iPad option writes the iOS declaration on USER.
- Keys the app doesn't know are kept and written back unchanged.

## Product decisions

- Jamf School: no scope editing and no new-Blueprint creation (no device group list). Deploy stays available and shows group IDs instead of names and counts. Scope editing is a Jamf Pro feature.
- App Store lookups are logged in the activity log as "App Store" and are not retried. Lookups never include Jamf data or credentials.
- Keep README's Permissions and Network tables complete when adding an endpoint or host.

## Watchlist

What this app waits for from Apple, Jamf or Microsoft, or must recheck: see WATCHLIST.md.

## Testing

- **Unit tests** (Swift Testing, `AppSettings2BlueprintTests`): scheme `AppSettings2Blueprint`, ⌘U or `xcodebuild test -scheme AppSettings2Blueprint`. No real network: `Support/MockURLProtocol` and `JTKitTestSupport`.
- **UI tests** (`AppSettings2BlueprintUITests`, own scheme): never run the full suite or `Scripts/run-ui-tests.sh` without test names, unless Jordy asks for it by name (see "Testing" in JTKit's CLAUDE.md). For a single named test: `Scripts/run-ui-tests.sh Class/testName`. Use the script, not the Xcode MCP (Xcode crashed during UI test runs). They drive the Debug build and need no Jamf credentials.
  - On failure: UI tree in `/tmp/as2b-uidump.txt`, screenshots in `/tmp/as2b-uitest-attachments`.
  - `ScreenshotUITests` regenerates the README screenshots in `docs/`; hands off the Mac while it runs.
  - Launch arguments (`-sidebarSelection`, `-checksForUpdates NO`, `-NSNavLastRootDirectory`) override UserDefaults writes. So persisted app state is read once into `@State`, never bound with `@AppStorage`.
  - XCUI on macOS 27: SwiftUI `Text` exposes its string as `value` (label empty); a SwiftUI `Table` is an outline; TabView tabs are `.tab` elements; confirmation-dialog buttons need sheet/dialog scoping (otherwise the Touch Bar copy matches); undo needs editing to end first (a focused text field keeps its typing on the window's undo stack).
  - Extend the `AppSettingsUITestCase` helpers instead of raw queries. Add accessibility identifiers or labels in the app when an element is hard to find.
- **Release check** (ROADMAP step 11): `Scripts/release-check.sh` (scheme "AppSettings2Blueprint Release Check"; `--local-jtkit` before a JTKit version is tagged). Own-project build against the published JTKit and sign-in, unit tests, `DemoSmokeUITests` in demo mode (the only UI tests it runs), live checks on jamf-test-a over the Platform API, report. Claude may run it unattended (nohup, poll). Tenants come only from the local allow-list outside git. Never name a tenant in this repo.
  - Live checks (`LiveCheckTests.swift`, skipped on ⌘U): an empty **static** `JTKTEST AS …` computer group (checked for 0 members before scoping and again before deploying; never a smart group), a `JTKTEST` Blueprint with one app setting created and written by `BlueprintWriter` with the app's own client and allow-list, deployed, read back, then removed. Backups go to a temporary folder. Deleting test objects is done only by the test code through JTKit's guarded network; the app's own allow-list still never sends DELETE or undeploy.
  - Verified 2026-10-28: a deployed Blueprint can be deleted directly (no undeploy). Jamf removes it in the background; until then the group's DELETE answers 422 `HAS_DEPENDENCIES`, so the check waits and retries only that answer.
  - The fingerprint compares `connectionProfiles`, `selectedConnectionProfileID`, `demoMode` (single settings: the preferences file also holds window frames), `Backups/` and the Keychain item names.

## Releasing

1. Set the version (`MARKETING_VERSION`, now 1.1) and build number (`CURRENT_PROJECT_VERSION`) of the app target.
2. CHANGELOG.md: move "Unreleased" under the new version; short, user-facing bullets. Update README.md if features, permissions or hosts changed.
3. Build from `AppSettings2Blueprint.xcodeproj` against the published JTKit. Hardened Runtime stays on; the app is not sandboxed.
4. Jordy does the Developer ID signing and notarisation himself. Zip the notarised app he supplies with `ditto -c -k --keepParent` and attach it to `gh release create`, tagged `vX.Y.Z`. The updater reads GitHub's latest release, so the tag must be a version (suffixes like `v1.2.1-hotfix` are understood).
5. A shields release badge fetched before the release exists stays cached: purge GitHub's camo cache after shields' 5-minute cache has expired.
6. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.

Before any of this, follow the release gate in JTKit/ROADMAP.md.

## Repo conventions

Public MIT repo under github.com/JordyThery, laid out like his other apps: README with centred `docs/icon.png`, tagline, release/macOS/licence badges, a "Support" section linking buymeacoffee.com/jordythery, and `.github/FUNDING.yml`. Bundle IDs start with `be.jordythery.`.

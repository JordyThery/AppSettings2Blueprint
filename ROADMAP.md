# AppSettings2Blueprint: roadmap

Nothing is planned. These are unscheduled ideas, researched in October 2026 and not built; each needs Jordy's go-ahead before work starts.

## Ideas

- **Restrictions → App Settings:** convert the app lists of a Restrictions payload (`com.apple.applicationaccess`) into App Settings. On iOS and tvOS, `blockedAppBundleIDs` and `allowListedAppBundleIDs` (deprecated in 27.0, and the older `blacklistedAppBundleIDs` and `whitelistedAppBundleIDs`) map one to one to DeniedApps and AllowedApps; Apple's schema points to `com.apple.configuration.app.settings` for them. The macOS form (`com.apple.applicationaccess.new`) maps poorly: its path lists have no DeniedBinaries equivalent (that needs a CDHash, TeamID or SigningID). Sources would be Jamf Pro's classic mobile device configuration profiles (an extra `configuration-profiles:read` permission) and the `com.jamf.ddm-configuration-profile` components of Blueprints (no extra permission).
- **Rename a Blueprint:** change a Blueprint's name and description from the app. PATCH of `name` or `description` returns 204 and leaves the deployment state as it was (see "Verified Jamf behavior" in CLAUDE.md for the limits). Not yet checked on Jamf School.
- **PPPC → Privacy:** convert the PPPC services Apple deprecates in macOS 27 (Accessibility, Camera, Microphone, SpeechRecognition, BluetoothAlways) into App Settings permission defaults. The identity maps directly (`<Identifier> {<CodeRequirement>}`), but the meaning differs: a PPPC grant is silent and enforced, a permission default is a suggestion behind one consent prompt; PPPC's deny-only services can't be converted; path identifiers and non-AppKit processes (daemons, extensions) don't apply; and OrganizationJustification has no PPPC source.

## Code clean-ups (unscheduled)

- Use JTKit's `BlueprintDetail.isUnchangedInStepsAndScope(in:)` and `Blueprints.startDeployment(id:check:)` (JTKit 1.4.0, made from this app) instead of the app's own copies in `BlueprintWriter` and `DeployModel`.

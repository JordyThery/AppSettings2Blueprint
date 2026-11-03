import AppKit
import JTKit
import SwiftUI

/// The Connections tab of JTKit's Settings window (`SettingsWindow`), between
/// its General tab and its Updates tab: JTKit's shared list and
/// editor for the saved Jamf Platform API connections.
struct ConnectionsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.profileStore
        ConnectionsSettingsTab(
            store: store.connections,
            services: [.jamfPlatform],
            allowsChangingService: false,
            roles: [.active(selection: $store.selectedProfileID, demo: model.demoChoice)],
            footer: "Requires an API client with blueprints:read, blueprints:create, blueprints:update, blueprints:deploy and device-groups:read. Load Environments lists the environments an organization-scope integration can see; otherwise copy the Environment ID from the integration’s details in Jamf Account. The client secret is stored in your login Keychain.",
            newRecord: { _ in store.newProfile() },
            didDelete: { _ in store.profileWasDeleted() },
            test: { profile, typed in try await model.testConnection(profile, typedSecret: typed[.main]) },
            environments: { profile, typed in try await model.environments(for: profile, typedSecret: typed[.main]) }
        )
    }
}

/// The app's section of JTKit's General tab: what backups
/// hold, how long they're kept, and where they are.
struct BackupSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Backups") {
            Picker("Keep backups", selection: $model.backupRetention) {
                ForEach(BackupStore.Retention.allCases) { Text($0.title).tag($0) }
            }
            Text("A backup of the whole Blueprint is written before every change, including the settings of its other components, such as Wi-Fi passwords. Backups are plain JSON files that only your user account can read. The newest backup of each Blueprint is always kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Backups in Finder") {
                let root = model.backupRoot
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                NSWorkspace.shared.open(root)
            }
        }
    }
}

extension AppModel {
    /// The read permissions Test Connection checks. Write permissions can't be
    /// checked without writing, so they stay in the footer.
    static let readChecks: [JamfPlatform.PermissionCheck] = [.blueprintsRead, .deviceGroupsRead]

    /// Test Connection in Settings: signs in, then checks that the Blueprint
    /// and device group lists can be read, with the editor's values, saved or
    /// not. A secret typed in the editor is used instead of the stored one.
    /// Always the real connection on the real network, also in demo mode.
    func testConnection(_ profile: ConnectionProfile, typedSecret: String?) async throws -> String {
        let secret = try typedSecret ?? storedSecret(for: profile)
        let client = try makeClient(credentials: PlatformCredentials(profile: profile, secret: secret))
        try await client.signIn()
        let results = await client.checkPermissions(Self.readChecks)
        if let problem = JamfPlatform.PermissionProblem(results) { throw problem }
        let page = try await JamfPlatform.Blueprints(client: client).listPage(page: 0, pageSize: 1)
        let count = page.totalCount.map { "\($0) Blueprint\($0 == 1 ? "" : "s")" } ?? "Blueprint list OK"
        return "Connected · \(count) · device groups OK"
    }

    /// The saved secret for Test Connection and Load Environments; empty when
    /// none is saved. A Keychain that can't be read is reported as such.
    private func storedSecret(for profile: ConnectionProfile) throws -> String {
        do {
            return try profileStore.readSecret(for: profile) ?? ""
        } catch let error as SecretStoreError {
            throw APIError.keychainUnreadable(connection: profile.menuTitle, status: error.status)
        }
    }

    /// Load Environments in Settings: the environments the editor's
    /// integration can see. No Environment ID is needed for this.
    func environments(for profile: ConnectionProfile, typedSecret: String?) async throws -> [JamfPlatform.Environment] {
        let secret = try (typedSecret ?? storedSecret(for: profile)).trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = PlatformCredentials(profile: profile, secret: secret)
        let recorder = RequestRecorder(session: session, log: activityLog, service: ConnectionService.jamfPlatform.displayName,
                                       connection: credentials.connectionName.isEmpty ? nil : credentials.connectionName)
        return try await JamfPlatform.environments(
            for: credentials.connection, secret: { secret }, recorder: recorder,
            permits: { RequestAllowList.isPermitted(method: $0.method.uppercased(), path: $0.path) })
    }
}

import Foundation
import JTKit
import SwiftUI

/// The Connections tab of JTKit's Settings window (`SettingsWindow`), between
/// its General tab (Appearance) and its Updates tab: JTKit's shared list and
/// editor for the saved Jamf Platform API connections.
struct ConnectionsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.profileStore
        ConnectionsSettingsTab(
            store: store.connections,
            services: [.jamfPlatform],
            allowsChangingService: false,
            roles: [.active(selection: $store.selectedProfileID)],
            footer: "Requires an API client with blueprints:read, blueprints:create, blueprints:update, blueprints:deploy and device-groups:read. Load Environments lists the environments an organization-scope integration can see; otherwise copy the Environment ID from the integration’s details in Jamf Account. The client secret is stored in your login Keychain.",
            newRecord: { _ in store.newProfile() },
            didDelete: { _ in store.profileWasDeleted() },
            test: { profile, typed in try await model.testConnection(profile, typedSecret: typed[.main]) },
            environments: { profile, typed in try await model.environments(for: profile, typedSecret: typed[.main]) }
        )
    }
}

extension AppModel {
    /// The read permissions Test Connection checks. Write permissions can't be
    /// checked without writing, so they stay in the footer.
    static let readChecks: [JamfPlatform.PermissionCheck] = [.blueprintsRead, .deviceGroupsRead]

    /// Test Connection in Settings: signs in, then checks that the Blueprint
    /// and device group lists can be read, with the editor's values, saved or
    /// not. A secret typed in the editor is used instead of the stored one.
    func testConnection(_ profile: ConnectionProfile, typedSecret: String?) async throws -> String {
        let secret = typedSecret ?? profileStore.secret(for: profile) ?? ""
        let client = try makeClient(credentials: PlatformCredentials(profile: profile, secret: secret))
        try await client.signIn()
        let results = await client.checkPermissions(Self.readChecks)
        if let problem = ConnectionTestProblem(results) { throw problem }
        let page = try await JamfPlatform.Blueprints(client: client).listPage(page: 0, pageSize: 1)
        let count = page.totalCount.map { "\($0) blueprint\($0 == 1 ? "" : "s")" } ?? "blueprint list OK"
        return "Connected · \(count) · device groups OK"
    }

    /// Load Environments in Settings: the environments the editor's
    /// integration can see. No Environment ID is needed for this.
    func environments(for profile: ConnectionProfile, typedSecret: String?) async throws -> [JamfPlatform.Environment] {
        let secret = (typedSecret ?? profileStore.secret(for: profile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = PlatformCredentials(profile: profile, secret: secret)
        let recorder = RequestRecorder(log: activityLog, service: ConnectionService.jamfPlatform.displayName,
                                       connection: credentials.connectionName.isEmpty ? nil : credentials.connectionName)
        return try await JamfPlatform.environments(
            for: credentials.connection, secret: { secret }, recorder: recorder,
            permits: { RequestAllowList.isPermitted(method: $0.method.uppercased(), path: $0.path) })
    }
}

/// Signing in worked, but a read permission is missing or couldn't be checked.
/// Each check gets one line: what to add, or why it couldn't be checked.
nonisolated struct ConnectionTestProblem: LocalizedError {
    let missing: [JamfPlatform.PermissionCheck]
    let unchecked: [(check: JamfPlatform.PermissionCheck, reason: String)]

    init?(_ results: [(check: JamfPlatform.PermissionCheck, result: JamfPlatform.PermissionResult)]) {
        var missing = [JamfPlatform.PermissionCheck]()
        var unchecked = [(check: JamfPlatform.PermissionCheck, reason: String)]()
        for (check, result) in results {
            switch result {
            case .allowed: break
            case .missingPermission: missing.append(check)
            case .notFound: unchecked.append((check, "not found (HTTP 404)"))
            case .failed(let status): unchecked.append((check, "HTTP \(status)"))
            case .unreachable(let message): unchecked.append((check, message))
            }
        }
        guard !missing.isEmpty || !unchecked.isEmpty else { return nil }
        self.missing = missing
        self.unchecked = unchecked
    }

    var errorDescription: String? {
        missing.isEmpty
            ? "Signed in, but not every permission could be checked."
            : "Signed in, but the API integration is missing \(missing.count == 1 ? "a permission" : "permissions"): \(missing.map(\.permission).joined(separator: ", "))."
    }

    var failureReason: String? {
        let lines = missing.map(\.hint) + unchecked.map { "\($0.check.name) couldn’t be checked: \($0.reason)" }
        return lines.joined(separator: "\n")
    }
}

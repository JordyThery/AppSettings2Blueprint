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
            footer: "Requires an API client with blueprints:read, blueprints:create, blueprints:update, blueprints:deploy and device-groups:read. The Environment ID cannot be looked up through the API; copy it from Jamf. The client secret is stored in your login Keychain.",
            newRecord: { _ in store.newProfile() },
            didDelete: { _ in store.profileWasDeleted() },
            test: { profile, typed in try await model.testConnection(profile, typedSecret: typed[.main]) }
        )
    }
}

extension AppModel {
    /// Test Connection in Settings: fetches a token, then calls
    /// GET /blueprints/v1/blueprints?page-size=1 and
    /// GET /device-groups/v1/device-groups?page-size=1 with the editor's values,
    /// saved or not. A secret typed in the editor is used instead of the stored one.
    func testConnection(_ profile: ConnectionProfile, typedSecret: String?) async throws -> String {
        let secret = typedSecret ?? profileStore.secret(for: profile) ?? ""
        let client = makeClient(credentials: PlatformCredentials(profile: profile, secret: secret))
        try await client.refreshToken()
        let page = try await BlueprintService(client: client).listPage(page: 0, pageSize: 1)
        let count = page.totalCount.map { "\($0) blueprint\($0 == 1 ? "" : "s")" } ?? "blueprint list OK"
        do {
            _ = try await client.send(
                method: "GET",
                path: "/device-groups/v1/device-groups",
                query: [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")]
            )
        } catch {
            throw DeviceGroupsTestError(blueprints: count, underlying: error)
        }
        return "Connected · \(count) · device groups OK"
    }
}

/// Signing in and listing blueprints worked, but device groups did not.
private struct DeviceGroupsTestError: LocalizedError {
    let blueprints: String
    let underlying: any Error

    var errorDescription: String? {
        "Connected · \(blueprints), but device groups failed (is device-groups:read granted?)"
    }

    var failureReason: String? { underlying.localizedDescription }
}

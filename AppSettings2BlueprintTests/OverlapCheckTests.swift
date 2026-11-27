import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

private let targetID = "0a1b2c3d-4444-4444-8444-0123456789ab"
private let otherID = "0a1b2c3d-5555-4555-8555-0123456789ab"
private let list = #"{"totalCount":2,"results":[{"id":"\#(targetID)","name":"Target"},{"id":"\#(otherID)","name":"Other"}]}"#

@Suite("Write to Jamf: the overlap check says what it can't see yet")
@MainActor
struct OverlapCheckTests {
    private func listed(_ app: AppModel) async throws {
        app.refresh()
        for _ in 0..<300 where app.overviews.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(app.overviews.count == 2)
    }

    @Test("A Blueprint being loaded counts as being checked; one that failed, or that nothing loads, as not checked")
    func uncheckedBlueprints() async throws {
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token":"tok","expires_in":900}"#) }
            if request.path.hasSuffix(otherID) {
                Thread.sleep(forTimeInterval: 0.3)
                return .json(404, "{}")
            }
            return .json(200, list)
        }
        let app = TestApp.model(session: server.session, connected: true)
        try await listed(app)
        let model = JamfWriteModel(app: app)
        model.selectedBlueprintID = targetID
        #expect(model.uncheckedForOverlap == (0, 0), "the target isn't loaded: no groups to compare yet")

        app.storeDetail(try JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8)))
        #expect(model.uncheckedForOverlap == (0, 1), "nothing is loading the other one")

        let loading = Task { await app.loadMissingDetails() }
        for _ in 0..<300 where !app.loadingDetailIDs.contains(otherID) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.uncheckedForOverlap == (1, 0))
        await loading.value
        #expect(model.uncheckedForOverlap == (0, 1))
    }

    @Test("With no client (a locked Keychain), every missing Blueprint is marked as not loaded")
    func noClient() async throws {
        let secrets = InMemorySecretStore()
        let defaults = TestApp.defaults()
        let store = ProfileStore(defaults: defaults, secrets: secrets)
        let profile = ConnectionProfile(name: "Test", region: .eu, environmentID: testEnvironmentID, clientID: "client-1")
        try store.connections.save(profile, secrets: [.main: "secret"])
        store.selectedProfileID = profile.id
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token":"tok","expires_in":900}"#) }
            return .json(200, list)
        }
        let app = AppModel(profileStore: store, session: server.session, defaults: defaults, backupRoot: TestApp.temporaryFolder())
        try await listed(app)
        secrets.refusesReads = true
        await app.loadMissingDetails()
        #expect(app.detailErrors[targetID] != nil)
        #expect(app.detailErrors[otherID] != nil)
        #expect(app.loadingDetailIDs.isEmpty)
    }
}

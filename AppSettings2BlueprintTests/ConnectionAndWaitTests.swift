import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

private let blueprintID = "0a1b2c3d-4444-4444-8444-0123456789ab"
private let blueprintPath = "/blueprints/v1/blueprints/\(blueprintID)"
private let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)

private func detail(_ json: String = appSettingsBlueprintJSON) -> JamfPlatform.BlueprintDetail {
    try! JamfPlatform.BlueprintDetail(data: Data(json.utf8))
}

/// The fixture as Jamf answers for a Blueprint made in the Jamf UI: no `updated`.
private let withoutUpdated = appSettingsBlueprintJSON
    .replacingOccurrences(of: #""updated":"2026-10-02T09:30:00.222222Z""#, with: #""updated":null"#)

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Keychain problems are reported as such")
@MainActor
struct KeychainReadTests {
    private func model(refusing: Bool) throws -> (AppModel, ConnectionProfile) {
        let secrets = InMemorySecretStore()
        let defaults = TestApp.defaults()
        let store = ProfileStore(defaults: defaults, secrets: secrets)
        let profile = ConnectionProfile(name: "Test", region: .eu, environmentID: testEnvironmentID, clientID: "client-1")
        try store.connections.save(profile, secrets: [.main: "secret"])
        store.selectedProfileID = profile.id
        secrets.refusesReads = refusing
        return (AppModel(profileStore: store, session: MockURLProtocol.makeSession(), defaults: defaults), profile)
    }

    @Test("A Keychain that refuses or is locked isn't “No complete connection is configured”")
    func lockedKeychain() throws {
        let (model, _) = try model(refusing: true)
        do {
            _ = try model.currentClient()
            Issue.record("A client was made without the secret")
        } catch APIError.keychainUnreadable(let connection, let status) {
            #expect(connection == "Test (eu)")
            #expect(status == -25308)
            #expect(APIError.keychainUnreadable(connection: connection, status: status).localizedDescription.contains("Keychain"))
        }
    }

    @Test("A readable Keychain gives the client as before")
    func readableKeychain() throws {
        let (model, _) = try model(refusing: false)
        _ = try model.currentClient()
    }

    @Test("Test Connection reports the Keychain before signing in")
    func testConnectionReportsKeychain() async throws {
        let (model, profile) = try model(refusing: true)
        await #expect(throws: APIError.self) { _ = try await model.testConnection(profile, typedSecret: nil) }
    }
}

@Suite("Connection and demo switches")
@MainActor
struct ConnectionSwitchTests {
    @Test("A switch clears the rule set's link to a Blueprint of the old connection")
    func switchClearsLink() {
        let app = TestApp.model(connected: true)
        let loaded = detail()
        app.ruleSet.load(from: loaded, location: loaded.appSettingsLocations.first { $0.isStrictComponent }!)
        #expect(app.ruleSet.linkedBlueprint?.id == blueprintID)
        app.connectionDidChange()
        #expect(app.ruleSet.linkedBlueprint == nil)
        #expect(JamfWriteModel(app: app).selectedBlueprintID == nil)
    }

    @Test("Settings' Use This Connection knows demo mode's connection")
    func settingsKnowsDemo() {
        let app = TestApp.model(connected: true)
        #expect(app.demoChoice.connections.map(\.id) == [Connection.demoJamfPlatform.id])
        #expect(!app.demoChoice.isActive)
    }
}

@Suite("Concurrency check")
struct ConcurrencyCheckTests {
    @Test("Without “updated”, a field other than steps and scope may differ")
    func withoutUpdatedOtherFieldsMayDiffer() {
        let before = detail(withoutUpdated)
        let after = detail(withoutUpdated.replacingOccurrences(of: #""state":"DEPLOYED""#, with: #""state":"OUT_OF_DATE""#))
        #expect(BlueprintWriter.isUnchanged(loaded: before, latest: after))
    }

    @Test("Without “updated”, other steps or another scope count as changed")
    func withoutUpdatedStepsAndScopeDecide() {
        let before = detail(withoutUpdated)
        let steps = detail(withoutUpdated.replacingOccurrences(of: #""minimumLength":6"#, with: #""minimumLength":8"#))
        let scope = detail(withoutUpdated.replacingOccurrences(of: "11111111-2222-4333-8444-555555555555", with: "11111111-2222-4333-8444-666666666666"))
        #expect(!BlueprintWriter.isUnchanged(loaded: before, latest: steps))
        #expect(!BlueprintWriter.isUnchanged(loaded: before, latest: scope))
        // only one copy without "updated": the same rule
        #expect(BlueprintWriter.isUnchanged(loaded: detail(), latest: before))
        #expect(!BlueprintWriter.isUnchanged(loaded: detail(), latest: scope))
    }

    @Test("With “updated”, a newer time counts as changed")
    func withUpdated() {
        let newer = detail(appSettingsBlueprintJSON.replacingOccurrences(of: "2026-10-02T09:30:00.222222Z", with: "2026-10-03T09:30:00.222222Z"))
        #expect(BlueprintWriter.isUnchanged(loaded: detail(), latest: detail()))
        #expect(!BlueprintWriter.isUnchanged(loaded: detail(), latest: newer))
    }
}

extension MockNetworkTests {
    @Suite("Write to Jamf: a Blueprint that can't be loaded, and retry waits")
    @MainActor
    struct WriteSheetLoadingTests {
        @Test("A chosen Blueprint that isn't in the list is fetched, and its error shown instead of Loading…")
        func unlistedBlueprintShowsError() async throws {
            MockURLProtocol.install { request in
                request.path == "/auth/token" ? token : .json(404, #"{"httpStatus":404,"errors":[{"code":"NOT_FOUND"}]}"#)
            }
            let app = TestApp.model(connected: true)
            let write = JamfWriteModel(app: app)
            write.selectedBlueprintID = blueprintID
            write.loadSelectedDetailIfNeeded()
            await waitUntil { app.detailErrors[blueprintID] != nil }
            #expect(app.detailErrors[blueprintID] != nil)
            #expect(write.blockingReason?.contains("couldn’t be loaded") == true)
        }

        @Test("A wait before a retry shows in RequestWaits, and Stop ends it with nothing written")
        func stopDuringWait() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return MockResponse(status: 503, headers: ["Retry-After": "30"], body: Data("{}".utf8))
            }
            let app = TestApp.model(connected: true)
            let loaded = detail()
            app.storeDetail(loaded)
            app.ruleSet.load(from: loaded, location: loaded.appSettingsLocations.first { $0.isStrictComponent }!)
            app.ruleSet.update("Add") { $0.deniedApps.append(AppRule(bundleID: "com.apple.tips")) }
            let write = JamfWriteModel(app: app)
            let prepare = Task { await write.performPrepare() }
            await waitUntil { app.waits.statusText != nil }
            #expect(app.waits.statusText?.contains("Jamf asked to wait 30 s") == true)
            app.waits.cancelAll()
            await prepare.value
            guard case .failed(let message) = write.phase else {
                Issue.record("Expected the stopped message, got \(write.phase)")
                return
            }
            #expect(message == JamfWriteModel.stoppedText)
            #expect(MockURLProtocol.requests.allSatisfy { $0.method == "GET" || $0.path == "/auth/token" })
        }
    }
}

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

/// A refused-attempts log of the test's own, so these tests never add to the
/// attempts the release check reads.
private func temporaryLog() -> TestRun.AttemptLog {
    TestRun.AttemptLog(fileURL: TestSettings.folder.appending(path: "attempts-\(UUID().uuidString).jsonl"))
}

@MainActor
@Suite("Under tests: no saved connection, Keychain item or real setting")
struct UnderTestTests {
    @Test("The unit-test host counts as under tests")
    func hostIsUnderTest() {
        #expect(TestRun.isUnitTestHost)
        #expect(UnderTest.isActive)
    }

    @Test("The unit-test host's model has its own settings, no Keychain, Demo Mode off and no update check")
    func hostModel() {
        let model = AppModel.forLaunch()
        #expect(!model.profileStore.holdsSavedConnections)
        #expect(model.profileStore.profiles.isEmpty)
        #expect(model.defaults !== UserDefaults.standard)
        #expect(!model.demo.isOn)
        #expect(!model.checksForUpdates)
        #expect(model.backupRoot != BackupStore.rootURL)
    }

    @Test("The preview's model has its own settings, no Keychain and Demo Mode off")
    func previewModel() {
        let model = AppModel.preview()
        #expect(!model.profileStore.holdsSavedConnections)
        #expect(model.profileStore.profiles.isEmpty)
        #expect(model.defaults !== UserDefaults.standard)
        #expect(!model.demo.isOn)
        #expect(!model.checksForUpdates)
        #expect(model.backupRoot != BackupStore.rootURL)
    }

    @Test("Only the app's real settings or Keychain count as the saved connections")
    func whatCountsAsSaved() {
        let settings = TestSettings.makeDefaults("under-test")
        #expect(!ProfileStore(defaults: settings.defaults, secrets: InMemorySecretStore()).holdsSavedConnections)
        // The real Keychain items, but nothing is read: the list is empty.
        #expect(ProfileStore(defaults: settings.defaults, secrets: ProfileStore.keychain).holdsSavedConnections)
        #expect(ProfileStore(defaults: settings.defaults, secrets: InMemorySecretStore(), countsAsSaved: true).holdsSavedConnections)
    }

    @Test("Every request of a saved connection, sign-in included, is refused before the Keychain is read or anything is sent, and written down")
    func savedConnectionRequestsAreRefused() async throws {
        let log = temporaryLog()
        let secrets = CountingSecretStore()
        // A fake Jamf that answers everything: nothing may reach it.
        let server = MockServer { _ in .json(200, #"{"access_token": "x", "expires_in": 3600}"#) }
        let defaults = TestApp.defaults()
        let store = ProfileStore(defaults: defaults, secrets: secrets, countsAsSaved: true)
        let profile = ConnectionProfile(name: "Saved", region: .eu, environmentID: testEnvironmentID, clientID: "client-1")
        try store.connections.save(profile, secrets: [.main: "secret"])
        store.selectedProfileID = profile.id
        let model = AppModel(profileStore: store, session: server.session, defaults: defaults,
                             backupRoot: TestApp.temporaryFolder(), underTestLog: log)
        #expect(model.refusesSavedConnections)
        let readsBefore = secrets.readCount

        // The Blueprint list.
        model.refresh()
        for _ in 0..<500 where !model.isFailed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isFailed)
        // A sheet's own client (write, scope, restore, deploy).
        await #expect(throws: (any Error).self) { _ = try await model.service(waits: RequestWaits()).list() }
        // Test Connection and Load Environments in Settings.
        await #expect(throws: (any Error).self) { _ = try await model.testConnection(profile, typedSecret: nil) }
        await #expect(throws: (any Error).self) { _ = try await model.environments(for: profile, typedSecret: nil) }

        #expect(secrets.readCount == readsBefore, "the Keychain isn't read")
        let keychainAttempts = log.attempts().map(\.what)
        #expect(keychainAttempts.count == 4)
        #expect(keychainAttempts.allSatisfy { $0 == "Keychain read for a saved connection" })

        // A secret typed in Settings skips the Keychain; the sign-in is refused by the network.
        await #expect(throws: (any Error).self) { _ = try await model.testConnection(profile, typedSecret: "typed") }
        #expect(server.requests.isEmpty)
        let signIn = log.attempts().map(\.what).dropFirst(4)
        #expect(signIn.count == 1)
        #expect(signIn.allSatisfy { $0.hasPrefix("POST ") && $0.contains("api.jamfcloud.com") })
    }

    @Test("A refused request reads as no answer, never as a cancellation, and is written down without its query")
    func refusalShape() async throws {
        let log = temporaryLog()
        let session = UnderTest.refusingSession(log: log)
        let request = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/api/blueprints/v1/blueprints?page=0")!)
        let error = await #expect(throws: URLError.self) { _ = try await session.data(for: request) }
        #expect(error?.code == .resourceUnavailable)
        #expect(error?.localizedDescription == UnderTest.refusal)
        #expect(log.attempts().map(\.what) == ["GET eu.api.jamfcloud.com/api/blueprints/v1/blueprints"])
    }

    @Test("Demo Mode isn't refused: it's answered inside the app")
    func demoModeIsNotRefused() async throws {
        let log = temporaryLog()
        let defaults = TestApp.defaults()
        let store = ProfileStore(defaults: defaults, secrets: InMemorySecretStore(), countsAsSaved: true)
        let model = AppModel(profileStore: store,
                             demo: DemoMode(key: AppModel.demoModeKey, defaults: defaults, arguments: [DemoMode.launchArgument, "YES"]),
                             defaults: defaults, backupRoot: TestApp.temporaryFolder(), underTestLog: log)
        _ = try await model.currentService().list()
        #expect(log.attempts().isEmpty)
    }
}

private extension AppModel {
    var isFailed: Bool { if case .failed = listState { true } else { false } }
}


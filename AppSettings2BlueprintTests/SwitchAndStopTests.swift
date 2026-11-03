import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

private let blueprintID = "0a1b2c3d-4444-4444-8444-0123456789ab"
private let blueprintPath = "/blueprints/v1/blueprints/\(blueprintID)"
private let listPath = "/blueprints/v1/blueprints"
private let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)

private var fixture: JamfPlatform.BlueprintDetail {
    try! JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8))
}

/// Jamf asks to wait before the request is sent again.
private func wait(_ status: Int, seconds: Int) -> MockResponse {
    MockResponse(status: status, headers: ["Retry-After": "\(seconds)"], body: Data("{}".utf8))
}

private func requests(_ method: String) -> [RecordedRequest] {
    MockURLProtocol.requests.filter { $0.path != "/auth/token" && $0.method == method }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A connected model holding the fixture, its rule set loaded from it and edited.
@MainActor
private func editedModel() -> AppModel {
    let app = TestApp.model(connected: true)
    app.storeDetail(fixture)
    app.ruleSet.load(from: fixture, location: fixture.appSettingsLocations.first { $0.isStrictComponent }!)
    app.ruleSet.update("Add") { $0.deniedApps.append(AppRule(bundleID: "com.apple.tips")) }
    return app
}

/// A second saved connection, not in use.
@MainActor
private func addSecondConnection(to app: AppModel) throws -> ConnectionProfile {
    let second = ConnectionProfile(name: "Second", region: .us, environmentID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", clientID: "client-2")
    try app.profileStore.connections.save(second, secrets: [.main: "secret-2"])
    return second
}

extension MockNetworkTests {
    @Suite("Stop during a wait before a retry")
    @MainActor
    struct StopTests {
        @Test("Stop after a PATCH got a 5xx: the write may have reached Jamf, so Close only, saying the user stopped it")
        func stopAfterPatch() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "PATCH" ? wait(503, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            await model.performPrepare()
            guard case .review(let prepared) = model.phase else { Issue.record("No review: \(model.phase)"); return }
            let commit = Task { await model.performCommit(prepared) }
            await waitUntil { model.waits.statusText != nil }
            model.waits.cancelAll()
            await commit.value
            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("You stopped waiting for Jamf"))
            #expect(message.contains("may have reached Jamf"))
            #expect(requests("PATCH").count == 1)
        }

        @Test("Stop after a create got a 429: Close only, and the message says the user stopped it")
        func stopAfterCreate() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "POST" ? wait(429, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            let model = JamfWriteModel(app: app)
            model.mode = .new
            model.newName = "JTKTEST New"
            model.selectedGroupIDs = ["11111111-2222-4333-8444-555555555555"]
            let create = Task { await model.performPrepare() }
            await waitUntil { model.waits.statusText != nil }
            model.waits.cancelAll()
            await create.value
            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("You stopped waiting for Jamf while “JTKTEST New” was being created"))
            #expect(requests("POST").count == 1)
        }

        @Test("Stop during a scope change's wait: Close only")
        func stopDuringScopeChange() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "PATCH" ? wait(503, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            let model = EditScopeModel(app: app, detail: fixture)
            let save = Task { await model.performSave() }
            await waitUntil { model.waits.statusText != nil }
            model.waits.cancelAll()
            await save.value
            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("scope"))
            #expect(message.contains("You stopped waiting for Jamf"))
        }

        @Test("Stop during a restore's wait is the stopped error, which may have written")
        func stopDuringRestore() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "PATCH" ? wait(503, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            let url = try BackupStore.write(fixture, root: app.backupRoot)
            let saved = try #require(BackupStore.backups(for: blueprintID, root: app.backupRoot).first { $0.url.lastPathComponent == url.lastPathComponent })
            let waits = RequestWaits()
            let writer = try app.makeWriter(waits: waits)
            let restore = Task { try await writer.restore(saved, loaded: fixture) }
            await waitUntil { waits.statusText != nil }
            waits.cancelAll()
            do {
                _ = try await restore.value
                Issue.record("The restore finished although it was stopped")
            } catch let error as BlueprintWriter.WriteError {
                guard case .stopped(_, .restore) = error else { Issue.record("Expected stopped, got \(error)"); return }
                #expect(error.mayHaveWritten)
            }
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("Stop during the deploy's 429 wait: not started")
        func stopDuringDeployWait() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "POST" ? wait(429, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.isConfirmed = true
            let deploy = Task { await model.performDeploy() }
            await waitUntil { model.waits.statusText != nil }
            model.waits.cancelAll()
            await deploy.value
            guard case .failed(let message) = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(message.contains("wasn’t started"))
        }

        /// The deploy answers 202; every read after it waits 30 s.
        private func installDeployThenWait() {
            let deployed = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "POST" {
                    _ = deployed.next()
                    return MockResponse(status: 202, body: Data())
                }
                return deployed.value > 0 ? wait(503, seconds: 30) : .json(200, appSettingsBlueprintJSON)
            }
        }

        @Test("Stop during the watch: started, status unknown")
        func stopDuringWatch() async throws {
            installDeployThenWait()
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.poller = JamfPlatform.Poller(sleep: { _ in })
            model.isConfirmed = true
            let deploy = Task { await model.performDeploy() }
            await waitUntil { model.waits.statusText != nil }
            model.waits.cancelAll()
            await deploy.value
            guard case .watchFailed = model.phase else { Issue.record("Expected watchFailed, got \(model.phase)"); return }
        }

        @Test("Closing the sheet while watching sets no phase")
        func closingWhileWatching() async throws {
            installDeployThenWait()
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.poller = JamfPlatform.Poller(sleep: { _ in })
            model.isConfirmed = true
            model.deploy()
            await waitUntil { model.waits.statusText != nil }
            model.stopWatching()
            try await Task.sleep(for: .milliseconds(200))
            guard case .watching = model.phase else { Issue.record("Expected still watching, got \(model.phase)"); return }
        }
    }

    @Suite("Results that arrive after a connection switch")
    @MainActor
    struct LateResultTests {
        @Test("A write that finishes after a switch is shown, but neither stored nor linked")
        func lateWrite() async throws {
            let patches = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                guard request.method == "PATCH" else { return .json(200, appSettingsBlueprintJSON) }
                // the first attempt waits 1 s, the second succeeds
                return patches.next() == 1 ? wait(503, seconds: 1) : MockResponse(status: 204, body: Data())
            }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            await model.performPrepare()
            guard case .review(let prepared) = model.phase else { Issue.record("No review: \(model.phase)"); return }
            let commit = Task { await model.performCommit(prepared) }
            await waitUntil { model.waits.statusText != nil }
            app.connectionDidChange()
            await commit.value
            guard case .done = model.phase else { Issue.record("Expected done, got \(model.phase)"); return }
            #expect(app.details[blueprintID] == nil, "the old connection's Blueprint isn't stored")
            #expect(app.overviews.isEmpty)
            #expect(app.ruleSet.linkedBlueprint == nil, "nor linked")
            #expect(!model.isCurrentConnection)
        }

        @Test("A scope change that finishes after a switch isn't stored")
        func lateScopeChange() async throws {
            let patches = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                guard request.method == "PATCH" else { return .json(200, appSettingsBlueprintJSON) }
                return patches.next() == 1 ? wait(503, seconds: 1) : MockResponse(status: 204, body: Data())
            }
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            let model = EditScopeModel(app: app, detail: fixture)
            let save = Task { await model.performSave() }
            await waitUntil { model.waits.statusText != nil }
            app.connectionDidChange()
            await save.value
            guard case .done = model.phase else { Issue.record("Expected done, got \(model.phase)"); return }
            #expect(app.details.isEmpty && app.overviews.isEmpty)
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("A deploy from the write sheet uses the write's connection: after a switch nothing is sent")
        func deployAfterSwitch() async throws {
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, appSettingsBlueprintJSON) }
            let app = TestApp.model(connected: true)
            let generation = app.connectionGeneration
            app.connectionDidChange()
            let model = DeployModel(app: app, detail: fixture, generation: generation)
            model.isConfirmed = true
            await model.performDeploy()
            guard case .failed = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(requests("POST").isEmpty)
        }
    }

    @Suite("The model applies connection switches")
    @MainActor
    struct SwitchTests {
        @Test("Choosing another connection anywhere clears the old tenant's data and the link, without the main window")
        func selectionSwitch() async throws {
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            app.ruleSet.load(from: fixture, location: fixture.appSettingsLocations.first { $0.isStrictComponent }!)
            let generation = app.connectionGeneration
            let second = try addSecondConnection(to: app)
            app.profileStore.selectedProfileID = second.id
            await waitUntil { app.connectionGeneration != generation }
            #expect(app.connectionGeneration == generation + 1)
            #expect(app.overviews.isEmpty && app.details.isEmpty)
            #expect(app.ruleSet.linkedBlueprint == nil)
        }

        @Test("Turning Demo Mode on is applied by the model")
        func demoSwitch() async throws {
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            let generation = app.connectionGeneration
            app.demo.isOn = true
            await waitUntil { app.connectionGeneration != generation }
            #expect(app.details.isEmpty)
            app.demo.isOn = false
        }

        @Test("Renaming the connection in use keeps the editor's link and the loaded Blueprints")
        func renameKeepsLink() async throws {
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            app.ruleSet.load(from: fixture, location: fixture.appSettingsLocations.first { $0.isStrictComponent }!)
            let generation = app.connectionGeneration
            var profile = try #require(app.profileStore.selectedProfile)
            profile.name = "Renamed"
            try app.profileStore.connections.save(profile)
            try await Task.sleep(for: .milliseconds(100))
            #expect(app.profileStore.selectedProfile?.name == "Renamed")
            #expect(app.connectionGeneration == generation)
            #expect(app.ruleSet.linkedBlueprint?.id == blueprintID)
            #expect(app.details[blueprintID] != nil)
        }

        @Test("Changing the connection's Environment ID is a switch")
        func environmentChangeSwitches() async throws {
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            let generation = app.connectionGeneration
            var profile = try #require(app.profileStore.selectedProfile)
            profile.environmentID = "aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff"
            try app.profileStore.connections.save(profile)
            await waitUntil { app.connectionGeneration != generation }
            #expect(app.details.isEmpty)
        }

        @Test("Refresh clears the selection when the list no longer has its Blueprint")
        func refreshClearsDroppedSelection() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return .json(200, #"{"totalCount":0,"results":[]}"#)
            }
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            app.selectedBlueprintID = blueprintID
            app.refresh()
            await waitUntil { if case .finished = app.listState { true } else { false } }
            #expect(app.selectedBlueprintID == nil)
        }
    }

    @Suite("A Keychain that can't be read, in the list and details")
    @MainActor
    struct KeychainListTests {
        private func lockedModel() throws -> AppModel {
            let secrets = InMemorySecretStore()
            let defaults = TestApp.defaults()
            let store = ProfileStore(defaults: defaults, secrets: secrets)
            let profile = ConnectionProfile(name: "Test", region: .eu, environmentID: testEnvironmentID, clientID: "client-1")
            try store.connections.save(profile, secrets: [.main: "secret"])
            store.selectedProfileID = profile.id
            secrets.refusesReads = true
            return AppModel(profileStore: store, session: MockURLProtocol.makeSession(), defaults: defaults,
                            backupRoot: TestApp.temporaryFolder())
        }

        @Test("Refresh reports the Keychain")
        func refreshReportsKeychain() async throws {
            let app = try lockedModel()
            app.refresh()
            await waitUntil { if case .failed = app.listState { true } else { false } }
            guard case .failed(let message) = app.listState else { Issue.record("Expected failed, got \(app.listState)"); return }
            #expect(message.contains("Keychain"))
        }

        @Test("A detail reports the Keychain")
        func detailReportsKeychain() async throws {
            let app = try lockedModel()
            app.loadDetail(id: blueprintID)
            await waitUntil { app.detailErrors[blueprintID] != nil }
            #expect(app.detailErrors[blueprintID]?.contains("Keychain") == true)
        }
    }

    @Suite("Changed in Jamf: the next try starts from Jamf's copy")
    @MainActor
    struct ChangedInJamfTests {
        @Test("A Blueprint changed in Jamf is stored as it is now, so Back reviews the current state")
        func changedStoresLatest() async throws {
            let newer = appSettingsBlueprintJSON.replacingOccurrences(of: "2026-10-02T09:30:00.222222Z", with: "2026-10-04T09:30:00.222222Z")
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, newer) }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            await model.performPrepare()
            guard case .failed = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(app.details[blueprintID]?.overview.updated == "2026-10-04T09:30:00.222222Z")
            await model.performPrepare()
            guard case .review = model.phase else { Issue.record("Expected the review on the second try, got \(model.phase)"); return }
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("A scope changed by someone else stops Change Scope, even with the same “updated”")
        func scopeChangedSameUpdated() async throws {
            let other = appSettingsBlueprintJSON.replacingOccurrences(of: "11111111-2222-4333-8444-555555555555", with: "11111111-2222-4333-8444-666666666666")
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, other) }
            let app = TestApp.model(connected: true)
            await #expect(throws: BlueprintWriter.WriteError.self) {
                _ = try await app.makeWriter().changeScope(loaded: fixture, deviceGroups: ["g-2"])
            }
            #expect(requests("PATCH").isEmpty)
        }
    }
}

@Suite("Backup folders")
struct BackupFolderTests {
    @Test("An unsafe Blueprint ID stays inside the backup folder", arguments: ["", ".", ".."])
    func unsafeIDs(id: String) {
        let root = TestApp.temporaryFolder()
        let folder = BackupStore.directory(for: id, root: root)
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path() == root.standardizedFileURL.path())
        #expect(folder.lastPathComponent.hasPrefix("_"))
    }
}

@Suite("Concurrency check: only one copy has “updated”")
struct OneUpdatedTests {
    private let withoutUpdated = appSettingsBlueprintJSON
        .replacingOccurrences(of: #""updated":"2026-10-02T09:30:00.222222Z""#, with: #""updated":null"#)

    @Test("Loaded without “updated”, latest with it, same steps and scope: unchanged")
    func onlyLatestHasUpdated() throws {
        let loaded = try JamfPlatform.BlueprintDetail(data: Data(withoutUpdated.utf8))
        #expect(BlueprintWriter.isUnchanged(loaded: loaded, latest: fixture))
        #expect(BlueprintWriter.isUnchanged(loaded: fixture, latest: loaded))
    }
}

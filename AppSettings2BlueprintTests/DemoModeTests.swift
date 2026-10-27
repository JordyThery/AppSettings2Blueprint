import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import AppSettings2Blueprint

/// A secret store that counts reads and writes: demo mode must do neither.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var reads = 0
    private var writes = 0

    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }

    func secret(for account: String) -> String? {
        lock.withLock {
            reads += 1
            return secrets[account]
        }
    }

    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock {
            writes += 1
            secrets[account] = secret
        }
        return true
    }
}

/// The App Settings declarations of a Blueprint, decoded and encoded again.
private func declarations(of detail: JamfPlatform.BlueprintDetail) throws -> [LosslessJSON] {
    let location = try #require(AppSettingsLocator.locate(in: detail.json).first)
    let declarations = try #require(detail.json.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?.arrayValue)
    return DeclarationEncoder.declarations(for: DeclarationDecoder.decode(declarations: declarations).ruleSet)
}

@MainActor
@Suite("Demo mode", .serialized)
final class DemoModeTests {
    private let suiteName = "be.jordythery.appsettings2blueprint.tests.demo"
    private let defaults: UserDefaults
    private let secrets = CountingSecretStore()
    private let profile = ConnectionProfile(name: "Production", region: .eu,
                                            environmentID: "e77c1408-10c8-4007-b177-abc9157fbcaa", clientID: "client-1")

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A model with one saved connection (in use, with its secret) and demo
    /// mode on or off for this run only.
    private func makeModel(demo isOn: Bool = true, scenario: DemoScenario? = nil,
                           session: URLSession = .shared) throws -> AppModel {
        let store = ProfileStore(defaults: defaults, secrets: secrets)
        try store.connections.save(profile, secrets: [.main: "real-secret"])
        store.selectedProfileID = profile.id
        var arguments = [DemoMode.launchArgument, isOn ? "YES" : "NO"]
        if let scenario { arguments += [DemoMode.scenarioArgument, scenario.rawValue] }
        return AppModel(profileStore: store, demo: DemoMode(key: AppModel.demoModeKey, defaults: defaults, arguments: arguments),
                        session: session)
    }

    @Test("Demo mode lists Contoso's Blueprints and groups without reading or writing a saved connection or secret")
    func readsNothingSaved() async throws {
        let model = try makeModel()
        let savedProfiles = defaults.data(forKey: ProfileStore.profilesKey)
        let savedSelection = defaults.string(forKey: ProfileStore.selectedKey)
        let (reads, writes) = (secrets.readCount, secrets.writeCount)

        #expect(model.hasActiveConnection)
        #expect(try await model.currentService().list().count == 6)
        #expect(try await model.currentClient().deviceGroups().count == DemoSamples.platformGroups.count)

        #expect(secrets.readCount == reads, "no Keychain read")
        #expect(secrets.writeCount == writes, "no Keychain write")
        #expect(defaults.data(forKey: ProfileStore.profilesKey) == savedProfiles)
        #expect(defaults.string(forKey: ProfileStore.selectedKey) == savedSelection)
        #expect(defaults.object(forKey: AppModel.demoModeKey) == nil, "a run started with -JTKitDemo saves no choice")
        #expect(model.demo.jamfPlatformServer.requestCount > 0)
    }

    @Test("Test Connection uses the real connection and the real network, also while demo mode is on")
    func testConnectionStaysReal() async throws {
        let realNetwork = MockServer { request in
            if request.method == "POST" {
                return JTKitTestSupport.MockResponse.json(200, #"{"access_token":"t","expires_in":900,"token_type":"Bearer"}"#)
            }
            return JTKitTestSupport.MockResponse.json(200, #"{"totalCount":3,"results":[]}"#)
        }
        let model = try makeModel(session: realNetwork.session)
        #expect(model.demo.isOn)

        let message = try await model.testConnection(profile, typedSecret: nil)

        #expect(message.contains("3 blueprints"))
        #expect(!realNetwork.requests.isEmpty)
        #expect(realNetwork.requests.allSatisfy { $0.url.host() == "eu.api.jamfcloud.com" })
        #expect(realNetwork.requests.first?.bodyString.contains("real-secret") == true, "the saved secret")
        #expect(realNetwork.requests.dropFirst().allSatisfy { $0.header("X-Environment-Id") == profile.environmentID })
        #expect(model.demo.jamfPlatformServer.requestCount == 0, "nothing went to the demo")
    }

    @Test("Writes, scope changes and restores work, and back up only into demo mode's temporary folder")
    func writesBackUpIntoScratch() async throws {
        let model = try makeModel()
        #expect(model.backupRoot.path().hasPrefix(model.demo.scratchDirectory.path()))
        let id = DemoSamples.uuid(0xb002)
        #expect(!FileManager.default.fileExists(atPath: BackupStore.directory(for: id).path()))

        // Write the App Settings back into the deployed macOS Blueprint.
        let loaded = try await model.currentService().detail(id: id)
        let writer = try model.makeWriter()
        let prepared = try await writer.prepare(loaded: loaded, declarations: try declarations(of: loaded),
                                                target: .existingComponent(stepIndex: 0, componentIndex: 0))
        let result = try await writer.commit(prepared)
        #expect(result.problems.isEmpty)
        #expect(result.detail.overview.deploymentState?.state == .outOfDate)
        let backups = BackupStore.backups(for: id, root: model.backupRoot)
        #expect(backups.count == 1)

        // Restore that backup.
        let restored = try await model.makeWriter().restore(try #require(backups.first), loaded: result.detail)
        #expect(restored.problems.isEmpty)

        // Change the scope of the draft.
        let draft = try await model.currentService().detail(id: DemoSamples.uuid(0xb004))
        let scope = try await model.makeWriter().changeScope(loaded: draft, deviceGroups: [DemoSamples.platformGroups[1].id])
        #expect(scope.problems.isEmpty)

        // Create a new Blueprint.
        let created = try await model.makeWriter().create(
            name: "Contoso – Demo Test", description: nil, deviceGroups: [DemoSamples.platformGroups[0].id],
            stepName: "App Settings", activationPredicate: nil, declarations: try declarations(of: loaded))
        #expect(created.created && created.problems.isEmpty)

        #expect(!FileManager.default.fileExists(atPath: BackupStore.directory(for: id).path()), "nothing in the real Backups folder")
        try? FileManager.default.removeItem(at: model.demo.scratchDirectory)
    }

    @Test("A Blueprint without a scope is refused before any backup or change")
    func noScopeRefused() async throws {
        let model = try makeModel()
        let id = DemoSamples.uuid(0xb005)
        let loaded = try await model.currentService().detail(id: id)
        let macBlueprint = try await model.currentService().detail(id: DemoSamples.uuid(0xb002))
        await #expect(throws: BlueprintWriter.WriteError.self) {
            _ = try await model.makeWriter().prepare(loaded: loaded, declarations: try declarations(of: macBlueprint),
                                                     target: .newComponent(stepIndex: 0))
        }
        #expect(BackupStore.backups(for: id, root: model.backupRoot).isEmpty)
        #expect(model.demo.jamfPlatformServer.patchCount == 0)
    }

    @Test("The division's Blueprint is read-only")
    func divisionReadOnly() async throws {
        let model = try makeModel()
        let detail = try await model.currentService().detail(id: DemoSamples.uuid(0xb006))
        #expect(model.isReadOnly(detail))
    }

    @Test("The Jamf School scenario is recognised as Jamf School")
    func jamfSchoolScenario() async throws {
        let model = try makeModel(scenario: .jamfSchool)
        model.loadDeviceGroups()
        for _ in 0..<200 where model.isLoadingDeviceGroups || !model.isJamfSchool {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isJamfSchool)
        #expect(model.deviceGroups.isEmpty)
    }

    @Test("The picker shows no connection in demo mode; choosing one leaves demo mode and keeps it in use")
    func pickerSelection() throws {
        let model = try makeModel()
        let selection = profileSelection(model)
        #expect(selection.wrappedValue == nil)
        #expect(model.profileStore.selectedProfileID == profile.id, "the saved choice stays")

        selection.wrappedValue = profile.id
        #expect(!model.demo.isOn)
        #expect(selection.wrappedValue == profile.id)
    }

    @Test("Outside demo mode the saved connection and the real Backups folder are used")
    func realOutsideDemo() throws {
        let model = try makeModel(demo: false)
        #expect(model.backupRoot == BackupStore.rootURL)
        #expect(model.hasActiveConnection)
        _ = try model.currentClient()
        #expect(secrets.readCount > 0, "the saved secret is read for a real connection")
    }
}

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

private func apiRequests(_ method: String? = nil) -> [RecordedRequest] {
    MockURLProtocol.requests.filter { $0.path != "/auth/token" && (method == nil || $0.method == method) }
}

/// Waits for work a model started in its own Task.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A connected model holding the fixture, its rule set loaded from it and
/// edited, so there is something to write.
@MainActor
private func editedModel() -> AppModel {
    let app = TestApp.model(connected: true)
    let detail = fixture
    app.storeDetail(detail)
    app.ruleSet.load(from: detail, location: detail.appSettingsLocations.first { $0.isStrictComponent }!)
    app.ruleSet.update("Add") { $0.deniedApps.append(AppRule(bundleID: "com.apple.tips")) }
    return app
}

extension MockNetworkTests {
    @Suite("Write to Jamf: after the request was sent")
    @MainActor
    struct WriteOutcomeTests {
        @Test("A PATCH that succeeded but can't be read back is shown as written, never as Nothing Was Written")
        func patchSucceededReadBackFailed() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            let patched = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                switch request.method {
                case "PATCH":
                    _ = patched.next()
                    state.applyPatch(request.body)
                    return MockResponse(status: 204, body: Data())
                default:
                    // the read-back after the PATCH fails (not retried)
                    return patched.value > 0 ? .json(404, "{}") : .json(200, state.text)
                }
            }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            await model.performPrepare()
            guard case .review(let prepared) = model.phase else { Issue.record("No review: \(model.phase)"); return }
            await model.performCommit(prepared)

            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("was written"))
            #expect(!app.ruleSet.isDirty, "the rules were written: nothing to save")
            #expect(app.ruleSet.linkedBlueprint?.id == blueprintID)
            #expect(apiRequests("PATCH").count == 1)
        }

        @Test("A created Blueprint that can't be read back is linked, and the sheet can't create it again")
        func createSucceededReadBackFailed() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "POST" { return .json(201, #"{"id":"\#(blueprintID)"}"#) }
                return .json(404, "{}")
            }
            let app = editedModel()
            app.ruleSet.linkedBlueprint = nil
            let model = JamfWriteModel(app: app)
            model.mode = .new
            model.newName = "iPad apps"
            model.selectedGroupIDs = ["g1"]
            await model.performPrepare()

            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("Don’t create it again"))
            #expect(model.mode == .existing, "no way back to New Blueprint")
            #expect(model.selectedBlueprintID == blueprintID)
            #expect(app.ruleSet.linkedBlueprint?.id == blueprintID)
            #expect(apiRequests("POST").count == 1)
        }

        @Test("A create without a clear answer (5xx) may have created the Blueprint: not retried, no Back")
        func createWithoutClearAnswer() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "POST" { return .json(503, "{}") }
                return .json(200, #"{"totalCount":0,"results":[]}"#)
            }
            let app = editedModel()
            app.ruleSet.linkedBlueprint = nil
            let model = JamfWriteModel(app: app)
            model.mode = .new
            model.newName = "iPad apps"
            model.selectedGroupIDs = ["g1"]
            await model.performPrepare()

            guard case .uncertain(let message) = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(message.contains("may or may not have been created"))
            #expect(apiRequests("POST").count == 1)
            #expect(app.ruleSet.isDirty, "not known to be written")
        }

        @Test("A PATCH Jamf refuses (4xx) wrote nothing: the sheet offers Back")
        func refusedPatchWroteNothing() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "PATCH" { return .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID","description":"Bad"}]}"#) }
                return .json(200, appSettingsBlueprintJSON)
            }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            await model.performPrepare()
            guard case .review(let prepared) = model.phase else { Issue.record("No review"); return }
            await model.performCommit(prepared)
            guard case .failed = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(app.ruleSet.isDirty)
        }

        @Test("Nothing is sent after the connection changed while the sheet was open")
        func connectionChangedSendsNothing() async throws {
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, appSettingsBlueprintJSON) }
            let app = editedModel()
            let model = JamfWriteModel(app: app)
            model.selectedBlueprintID = blueprintID
            app.connectionDidChange()
            app.storeDetail(fixture)
            await model.performPrepare()
            guard case .failed(let message) = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(message.contains("connection changed"))
            #expect(apiRequests("POST").isEmpty && apiRequests("PATCH").isEmpty, "nothing written or deployed")
        }

        @Test("The review's second check stops the PATCH when the Blueprint changed in between")
        func changedBetweenReviewAndWrite() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "PATCH" { return MockResponse(status: 204, body: Data()) }
                return .json(200, state.text)
            }
            let app = editedModel()
            let writer = try app.makeWriter()
            let declarations = DeclarationEncoder.declarations(for: app.ruleSet.ruleSet)
            let prepared = try await writer.prepare(loaded: fixture, declarations: declarations,
                                                    target: .existingComponent(stepIndex: 0, componentIndex: 3))
            state.change(.string("Renamed"), at: [.key("name")])
            await #expect(throws: BlueprintWriter.WriteError.self) { _ = try await writer.commit(prepared) }
            #expect(apiRequests("PATCH").isEmpty)
        }
    }

    @Suite("Restore and scope outside demo mode")
    @MainActor
    struct RestoreAndScopeTests {
        @Test("A second restore in the same sheet compares with the state the first one left")
        func restoreTwice() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "PATCH" {
                    state.applyPatch(request.body)
                    return MockResponse(status: 204, body: Data())
                }
                return .json(200, state.text)
            }
            let app = TestApp.model(connected: true)
            let backup = try BackupStore.write(fixture, root: app.backupRoot)
            let saved = try #require(BackupStore.backups(for: blueprintID, root: app.backupRoot).first { $0.url.lastPathComponent == backup.lastPathComponent })

            let first = try await app.makeWriter().restore(saved, loaded: fixture)
            app.storeDetail(first.detail)
            // As the sheet does: the stored copy, not the one it opened with.
            let current = try #require(app.details[blueprintID])
            _ = try await app.makeWriter().restore(saved, loaded: current)
            await #expect(throws: BlueprintWriter.WriteError.self) {
                _ = try await app.makeWriter().restore(saved, loaded: fixture)
            }
            #expect(apiRequests("PATCH").count == 2)
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("A restore stops when the steps changed, even with the same updated date")
        func restoreStopsOnChangedSteps() async throws {
            let changedSteps = appSettingsBlueprintJSON.replacingOccurrences(of: "\"minimumLength\":6", with: "\"minimumLength\":8")
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, changedSteps) }
            let app = TestApp.model(connected: true)
            let url = try BackupStore.write(fixture, root: app.backupRoot)
            let saved = try #require(BackupStore.backups(for: blueprintID, root: app.backupRoot).first { $0.url.lastPathComponent == url.lastPathComponent })
            await #expect(throws: BlueprintWriter.WriteError.self) {
                _ = try await app.makeWriter().restore(saved, loaded: fixture)
            }
            #expect(apiRequests("PATCH").isEmpty)
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("A scope change whose read-back has different steps is reported")
        func scopeChangeReportsChangedSteps() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "PATCH" {
                    state.applyPatch(request.body)
                    state.change(.array([]), at: [.key("steps")])
                    return MockResponse(status: 204, body: Data())
                }
                return .json(200, state.text)
            }
            let app = TestApp.model(connected: true)
            let result = try await app.makeWriter().changeScope(loaded: fixture, deviceGroups: ["g-2"])
            #expect(result.problems.contains { $0.contains("steps changed") })
            try? FileManager.default.removeItem(at: app.backupRoot)
        }

        @Test("A scope change that can't be read back is shown as changed, not verified")
        func scopeChangeReadBackFailed() async throws {
            let patched = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "PATCH" {
                    _ = patched.next()
                    return MockResponse(status: 204, body: Data())
                }
                return patched.value > 0 ? .json(404, "{}") : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            app.storeDetail(fixture)
            // Groups not in the device group list can't be added, so the
            // current group is sent again: enough to test the read-back.
            let model = EditScopeModel(app: app, detail: fixture)
            await model.performSave()
            guard case .uncertain = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(apiRequests("PATCH").count == 1)
            try? FileManager.default.removeItem(at: app.backupRoot)
        }
    }

    @Suite("Deploy what was confirmed")
    @MainActor
    struct DeployCheckTests {
        private let poller = JamfPlatform.Poller(sleep: { _ in })

        @Test("A scope changed by someone else after the confirmation is shown again, unconfirmed, and nothing deploys")
        func changedScopeIsNotDeployed() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            state.change(.object(LosslessJSON.Object(["deviceGroups": .array([.string("other-group")])])), at: [.key("scope")])
            MockURLProtocol.install { request in
                request.path == "/auth/token" ? token : .json(200, state.text)
            }
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.isConfirmed = true
            await model.performDeploy()

            guard case .confirming = model.phase else { Issue.record("Expected confirming, got \(model.phase)"); return }
            #expect(!model.isConfirmed)
            #expect(model.changeNotice != nil)
            #expect(model.detail.scopeDeviceGroups == ["other-group"], "the confirmation shows the new scope")
            #expect(apiRequests("POST").isEmpty)
        }

        @Test("An unchanged Blueprint is deployed once")
        func unchangedIsDeployed() async throws {
            let deployed = Counter()
            let after = appSettingsBlueprintJSON.replacingOccurrences(
                of: #""lastDeployment":{"started":"2026-10-02T09:30:00.111111Z","state":"SUCCEEDED"}"#,
                with: #""lastDeployment":{"started":"2026-10-25T09:00:00Z","state":"SUCCEEDED"}"#)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.method == "POST" {
                    _ = deployed.next()
                    return MockResponse(status: 202, body: Data())
                }
                if request.path.hasSuffix("/report") { return .json(200, #"{"succeeded":1,"failed":0,"pending":0}"#) }
                return .json(200, deployed.value > 0 ? after : appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.poller = poller
            model.isConfirmed = true
            await model.performDeploy()
            guard case .finished(let status) = model.phase else { Issue.record("Expected finished, got \(model.phase)"); return }
            #expect(status.didSucceed)
            #expect(apiRequests("POST").map(\.path) == [blueprintPath + "/deploy"])
        }

        @Test("A deploy without a clear answer (5xx) may have started: not retried, not shown as Not Started")
        func deployWithoutClearAnswer() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                return request.method == "POST" ? .json(503, "{}") : .json(200, appSettingsBlueprintJSON)
            }
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.isConfirmed = true
            await model.performDeploy()
            guard case .uncertain = model.phase else { Issue.record("Expected uncertain, got \(model.phase)"); return }
            #expect(apiRequests("POST").count == 1)
        }

        @Test("Nothing is deployed after the connection changed while the sheet was open")
        func connectionChanged() async throws {
            MockURLProtocol.install { $0.path == "/auth/token" ? token : .json(200, appSettingsBlueprintJSON) }
            let app = TestApp.model(connected: true)
            let model = DeployModel(app: app, detail: fixture)
            model.isConfirmed = true
            app.connectionDidChange()
            await model.performDeploy()
            guard case .failed = model.phase else { Issue.record("Expected failed, got \(model.phase)"); return }
            #expect(apiRequests("POST").isEmpty && apiRequests("PATCH").isEmpty, "nothing written or deployed")
        }
    }

    @Suite("Blueprint list in Write to Jamf")
    @MainActor
    struct WriteSheetListTests {
        @Test("A detail that fails to load is reported, not left on Loading…")
        func detailFailureIsRecorded() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return token }
                if request.path == listPath {
                    return .json(200, #"{"totalCount":1,"results":[{"id":"\#(blueprintID)","name":"Sample iPad apps"}]}"#)
                }
                return .json(500, "{}")
            }
            let app = TestApp.model(connected: true)
            app.refresh()
            await waitUntil { app.overviews.count == 1 }
            await app.loadMissingDetails()
            #expect(app.details[blueprintID] == nil)
            #expect(app.detailErrors[blueprintID] != nil)
            #expect(!app.loadingDetailIDs.contains(blueprintID))
        }

        @Test("The sheet opens on Existing Blueprint until the list is known to be empty")
        func defaultMode() async throws {
            MockURLProtocol.install { request in
                request.path == "/auth/token" ? token : .json(200, #"{"totalCount":0,"results":[]}"#)
            }
            let app = TestApp.model(connected: true)
            let model = JamfWriteModel(app: app)
            #expect(model.mode == .existing, "the list hasn't loaded yet")
            app.refresh()
            await waitUntil { if case .finished = app.listState { true } else { false } }
            model.listDidChange()
            #expect(model.mode == .new)
        }
    }
}

@Suite("Write checks without a network")
@MainActor
struct WriteCheckTests {
    private func writer() throws -> BlueprintWriter {
        try TestApp.model(connected: true).makeWriter()
    }

    private var sentSteps: LosslessJSON { fixture.steps! }
    private let componentPath: [LosslessJSON.PathComponent] = [.key("steps"), .index(0), .key("components"), .index(3)]

    private func readBack(_ change: (inout LosslessJSON) -> Void) throws -> JamfPlatform.BlueprintDetail {
        var json = fixture.json
        change(&json)
        return try JamfPlatform.BlueprintDetail(data: json.serialized())
    }

    @Test("Verify reports a written component that came back different")
    func componentDiffers() throws {
        let back = try readBack { $0.setValue(.array([]), at: componentPath + [.key("configuration"), .key("declarations")]) }
        let result = try writer().verify(readBack: back, sentSteps: sentSteps, componentPath: componentPath, created: false)
        #expect(result.problems.contains { $0.contains("App Settings component") })
    }

    @Test("Verify reports a different number of steps")
    func stepCountDiffers() throws {
        let back = try readBack { $0.setValue(.array([]), at: [.key("steps")]) }
        let result = try writer().verify(readBack: back, sentSteps: sentSteps, componentPath: componentPath, created: false)
        #expect(result.problems.contains { $0.contains("steps after the write") })
    }

    @Test("Verify reports a dropped activation predicate")
    func predicateDropped() throws {
        var sent = sentSteps
        sent.setValue(.string("@status(device.operating-system.family) == 'iPadOS'"), at: [.index(0), .key("activationPredicate")])
        let result = try writer().verify(readBack: fixture, sentSteps: sent, componentPath: componentPath, created: false)
        #expect(result.problems.contains { $0.contains("activationPredicate") })
    }

    @Test("A removal from a Blueprint whose deployment state is unknown needs the acknowledgement")
    func removalWithUnknownState() throws {
        let unknown = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b1","name":"n","scope":{"deviceGroups":["g1","g2"]},"steps":[]}"#.utf8))
        let model = EditScopeModel(app: TestApp.model(), detail: unknown)
        model.selected = ["g1"]
        #expect(model.removalNeedsAcknowledgement)

        let neverDeployed = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b1","name":"n","scope":{"deviceGroups":["g1","g2"]},"deploymentState":{"state":"NOT_DEPLOYED"},"steps":[]}"#.utf8))
        let other = EditScopeModel(app: TestApp.model(), detail: neverDeployed)
        other.selected = ["g1"]
        #expect(!other.removalNeedsAcknowledgement)
    }

    @Test("An allow list in a component the app doesn't edit still needs the second confirmation, once per component")
    func allowListInOtherComponent() throws {
        let declaration = #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":{"AllowedBinaries":[{"TeamID":"ABCDE12345"}]}},"channelType":"SYSTEM"}"#
        let user = #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{},"channelType":"USER"}"#
        let detail = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b1","name":"Mac","scope":{"deviceGroups":["g1"]},"steps":[{"name":"S","components":[{"identifier":"com.jamf.ddm.custom-declarations","configuration":{"declarations":[\#(declaration),\#(user)]}}]}]}"#.utf8))
        let model = DeployModel(app: TestApp.model(), detail: detail)
        #expect(model.allowListWarnings.count == 1)
    }

    @Test("Return can't create a Blueprint: only Review Changes… is the default button")
    func createIsNotTheDefaultButton() {
        let model = JamfWriteModel(app: TestApp.model())
        model.mode = .existing
        #expect(model.primaryButtonIsDefault)
        model.mode = .new
        #expect(!model.primaryButtonIsDefault)
    }
}

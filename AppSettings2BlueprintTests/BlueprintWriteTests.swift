import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

/// A valid Environment ID: JTKit refuses one that isn't a UUID before sending.
let testEnvironmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"

/// Declarations of the fixture's App Settings component, decoded and re-encoded
/// the way the editor does.
private func reencodedDeclarations(_ blueprint: LosslessJSON, edit: (inout RuleSet) -> Void = { _ in }) throws -> [LosslessJSON] {
    let location = try #require(AppSettingsLocator.locate(in: blueprint).first)
    let declarations = try #require(blueprint.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?.arrayValue)
    var ruleSet = DeclarationDecoder.decode(declarations: declarations).ruleSet
    edit(&ruleSet)
    return DeclarationEncoder.declarations(for: ruleSet)
}

@Suite("Placement and round trip")
struct AppSettingsPlacementTests {
    private let blueprint = try! LosslessJSON(string: appSettingsBlueprintJSON)
    private let replaceTarget = AppSettingsTarget.existingComponent(stepIndex: 0, componentIndex: 3)

    @Test func noEditsLeaveStepsByteIdentical() throws {
        let edit = try AppSettingsLocator.edit(blueprint: blueprint, declarations: try reencodedDeclarations(blueprint), target: replaceTarget)
        let original = try #require(blueprint["steps"]).serializedString()
        #expect(edit.steps.serializedString() == original)
        #expect(appSettingsBlueprintJSON.contains(original))
        #expect(edit.unchangedComponentCount == 3)
    }

    @Test func editingOneDeniedAppChangesOnlyThatSubstring() throws {
        let declarations = try reencodedDeclarations(blueprint) { ruleSet in
            ruleSet.deniedApps[1].bundleID = "com.apple.tips"
        }
        let edit = try AppSettingsLocator.edit(blueprint: blueprint, declarations: declarations, target: replaceTarget)
        let original = try #require(blueprint["steps"]).serializedString()
        let expected = original.replacingOccurrences(of: #""com.apple.stocks""#, with: #""com.apple.tips""#)
        #expect(expected != original)
        #expect(edit.steps.serializedString() == expected)
        // The PATCH body is exactly {"steps": …}.
        let body = LosslessJSON.object(LosslessJSON.Object(["steps": edit.steps])).serializedString()
        #expect(body == #"{"steps":"# + expected + "}")
    }

    @Test func otherDeclarationsInTheComponentStayPut() throws {
        let edit = try AppSettingsLocator.edit(blueprint: blueprint, declarations: try reencodedDeclarations(blueprint) { $0.deniedApps = [AppRule(bundleID: "a.b")] }, target: replaceTarget)
        let declarations = try #require(edit.newComponent["configuration"]?["declarations"]?.arrayValue)
        #expect(declarations.count == 2)
        #expect(declarations[0]["type"]?.stringValue == "com.apple.configuration.keyboard.settings")
        #expect(declarations[0] == blueprint.value(at: [.key("steps"), .index(0), .key("components"), .index(3), .key("configuration"), .key("declarations"), .index(0)]))
    }

    @Test func macOSReplacesSystemInPlaceAndAddsUser() {
        let old: [LosslessJSON] = [
            .object(LosslessJSON.Object(["type": .string("com.apple.configuration.keyboard.settings")])),
            .object(LosslessJSON.Object(["type": .string(AppSettingsLocator.declarationType), "channelType": .string("SYSTEM"), "payload": .object(LosslessJSON.Object())])),
            .object(LosslessJSON.Object(["type": .string("com.apple.configuration.siri.settings")])),
        ]
        let system = LosslessJSON.object(LosslessJSON.Object(["type": .string(AppSettingsLocator.declarationType), "channelType": .string("SYSTEM"), "payload": .object(LosslessJSON.Object(["Allowed": .object(LosslessJSON.Object())]))]))
        let user = LosslessJSON.object(LosslessJSON.Object(["type": .string(AppSettingsLocator.declarationType), "channelType": .string("USER"), "payload": .object(LosslessJSON.Object())]))
        let merged = AppSettingsLocator.replacingAppSettings(in: old, with: [system, user])
        #expect(merged.map { $0["type"]?.stringValue ?? "" } == [
            "com.apple.configuration.keyboard.settings", AppSettingsLocator.declarationType,
            AppSettingsLocator.declarationType, "com.apple.configuration.siri.settings",
        ])
        #expect(merged[1]["payload"]?["Allowed"] != nil)
        #expect(merged[2]["channelType"]?.stringValue == "USER")

        // A channel the rule set no longer produces is removed.
        let withoutUser = AppSettingsLocator.replacingAppSettings(in: merged, with: [system])
        let userDeclarations = withoutUser.filter { $0["channelType"]?.stringValue == "USER" }
        #expect(userDeclarations.isEmpty)
        #expect(withoutUser.count == 3)
    }

    @Test func appendsNewComponentOrStep() throws {
        let json = try LosslessJSON(string: #"{"id":"x","steps":[{"name":"S","components":[{"identifier":"other","configuration":{}}],"activationPredicate":null}]}"#)
        let declarations = DeclarationEncoder.declarations(for: RuleSet(platform: .iOS, deniedApps: [AppRule(bundleID: "com.apple.news")]))
        #expect(AppSettingsLocator.defaultTarget(in: json) == .newComponent(stepIndex: 0))

        let component = try AppSettingsLocator.edit(blueprint: json, declarations: declarations, target: .newComponent(stepIndex: 0))
        #expect(component.componentPath.pathString == "steps[0].components[1]")
        #expect(component.steps[0]?["components"]?[0] == json["steps"]?[0]?["components"]?[0])
        #expect(component.steps[0]?["components"]?[1]?["identifier"]?.stringValue == "com.jamf.ddm-strict")

        let step = try AppSettingsLocator.edit(blueprint: json, declarations: declarations,
                                               target: .newStep(name: "iPad apps", activationPredicate: "@status(device.operating-system.family) == 'iPadOS'"))
        #expect(step.steps.arrayValue?.count == 2)
        #expect(step.steps[1]?.serializedString().hasPrefix(#"{"name":"iPad apps","components":[{"identifier":"com.jamf.ddm-strict""#) == true)
        #expect(step.steps[1]?["activationPredicate"]?.stringValue?.contains("iPadOS") == true)
        #expect(step.steps[0] == json["steps"]?[0])
    }

    @Test func refusesAFullStep() throws {
        let components = Array(repeating: #"{"identifier":"other","configuration":{}}"#, count: 100).joined(separator: ",")
        let json = try LosslessJSON(string: #"{"id":"x","steps":[{"components":[\#(components)]}]}"#)
        let declarations = DeclarationEncoder.declarations(for: RuleSet())
        #expect(throws: AppSettingsLocator.PlacementError.self) {
            try AppSettingsLocator.edit(blueprint: json, declarations: declarations, target: .newComponent(stepIndex: 0))
        }
    }

    @Test func emptyBlueprintGetsANewStep() throws {
        let json = try LosslessJSON(string: #"{"id":"x","steps":[]}"#)
        #expect(AppSettingsLocator.defaultTarget(in: json) == .newStep(name: "App Settings", activationPredicate: nil))
    }
}

/// The JSON comparison tests moved to JTKit with `LosslessJSON`.
@Suite("Line diff")
struct LineDiffTests {
    @Test func lineDiffMarksOnlyChangedLines() {
        let diff = TextDiff.lines(from: "a\nb\nc", to: "a\nB\nc\nd")
        #expect(diff.map(\.kind) == [.unchanged, .removed, .added, .unchanged, .added])
        let added = diff.filter { $0.kind == .added }.map(\.text)
        #expect(added == ["B", "d"])
    }
}

extension MockNetworkTests {
    @Suite("Blueprint writer")
    struct BlueprintWriterTests {
        private static let id = "0a1b2c3d-4444-4444-8444-0123456789ab"
        private static let path = "/blueprints/v1/blueprints/\(id)"
        private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)

        private func makeWriter(backups: BackupRecorder = BackupRecorder()) -> BlueprintWriter {
            let client = try! PlatformAPIClient.make(
                credentials: PlatformCredentials(region: .eu, environmentID: testEnvironmentID, clientID: "id", clientSecret: "secret"),
                session: MockURLProtocol.makeSession(),
                log: nil,
                sleep: { _ in }
            )
            var writer = BlueprintWriter(service: JamfPlatform.Blueprints(client: client))
            writer.backup = { detail in
                backups.record(detail)
                return URL(filePath: "/tmp/backup.json")
            }
            return writer
        }

        private var loaded: JamfPlatform.BlueprintDetail { try! JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8)) }

        private func apiRequests() -> [RecordedRequest] {
            MockURLProtocol.requests.filter { $0.path != "/auth/token" }
        }

        @Test func fullSaveFlowPatchesOnlyStepsAndVerifies() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                switch (request.method, request.path) {
                case ("GET", Self.path): return .json(200, state.text)
                case ("PATCH", Self.path):
                    state.applyPatch(request.body)
                    return MockResponse(status: 204, body: Data())
                default: return .json(404, "{}")
                }
            }
            let backups = BackupRecorder()
            let writer = makeWriter(backups: backups)
            let declarations = try reencodedDeclarations(loaded.json) { $0.deniedApps.append(AppRule(bundleID: "com.apple.tips")) }
            let prepared = try await writer.prepare(loaded: loaded, declarations: declarations, target: .existingComponent(stepIndex: 0, componentIndex: 3))
            #expect(backups.count == 1)
            let addsTips = prepared.diff.contains { $0.kind == .added && $0.text.contains("com.apple.tips") }
            #expect(addsTips)
            let onlyGets = apiRequests().allSatisfy { $0.method == "GET" }
            #expect(onlyGets)

            let result = try await writer.commit(prepared)
            #expect(result.isVerified, "\(result.problems)")
            let patch = try #require(apiRequests().first { $0.method == "PATCH" })
            #expect(patch.header("Content-Type") == "application/merge-patch+json")
            let body = try LosslessJSON(data: patch.body)
            #expect(body.objectValue?.keys == ["steps"])
            #expect(!patch.bodyString.contains("divisionId"))
            #expect(result.detail.json.serializedString().contains("com.apple.tips"))
        }

        @Test func changedBlueprintStopsBeforeBackupAndPatch() async throws {
            let changed = appSettingsBlueprintJSON.replacingOccurrences(of: "2026-10-02T09:30:00.222222Z", with: "2026-10-03T10:00:00Z")
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, changed) }
            let backups = BackupRecorder()
            await #expect(throws: BlueprintWriter.WriteError.self) {
                try await makeWriter(backups: backups).prepare(loaded: loaded, declarations: try reencodedDeclarations(loaded.json), target: .existingComponent(stepIndex: 0, componentIndex: 3))
            }
            #expect(backups.count == 0)
            let onlyGets = apiRequests().allSatisfy { $0.method == "GET" }
            #expect(onlyGets)
        }

        @Test func divisionConflictIsReportedAsReadOnly() async throws {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                if request.method == "PATCH" {
                    return .json(409, #"{"httpStatus":409,"errors":[{"code":"DIVISION_PATCH_NOT_ALLOWED","description":"Assigned to a division"}]}"#)
                }
                return .json(200, appSettingsBlueprintJSON)
            }
            let writer = makeWriter()
            let prepared = try await writer.prepare(loaded: loaded, declarations: try reencodedDeclarations(loaded.json) { $0.deniedApps = [] }, target: .existingComponent(stepIndex: 0, componentIndex: 3))
            do {
                _ = try await writer.commit(prepared)
                Issue.record("Expected a read-only error")
            } catch let error as BlueprintWriter.WriteError {
                guard case .readOnly = error else { Issue.record("Wrong error \(error)"); return }
            }
            // Conflicts are not retried.
            let patches = apiRequests().filter { $0.method == "PATCH" }
            #expect(patches.count == 1)
        }

        @Test func divisionLockedBlueprintIsNeverPatched() async throws {
            let locked = appSettingsBlueprintJSON.replacingOccurrences(of: #""description":null,"#, with: #""description":null,"divisionId":"d-1","#)
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, locked) }
            let detail = try JamfPlatform.BlueprintDetail(data: Data(locked.utf8))
            #expect(detail.isDivisionLocked)
            await #expect(throws: BlueprintWriter.WriteError.self) {
                try await makeWriter().prepare(loaded: detail, declarations: try reencodedDeclarations(detail.json), target: .existingComponent(stepIndex: 0, componentIndex: 3))
            }
            let patched = apiRequests().contains { $0.method == "PATCH" }
            #expect(!patched)
        }

        @Test func blueprintWithoutScopeIsRefusedBeforeBackup() async throws {
            // As created in the Jamf UI: scope null. The server answers 400 NotBlank (scopeId) to a PATCH.
            let unscoped = appSettingsBlueprintJSON.replacingOccurrences(of: #""scope":{"deviceGroups":["11111111-2222-4333-8444-555555555555"]}"#, with: #""scope":null"#)
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, unscoped) }
            let detail = try JamfPlatform.BlueprintDetail(data: Data(unscoped.utf8))
            #expect(detail.scopeDeviceGroups.isEmpty)
            let backups = BackupRecorder()
            do {
                _ = try await makeWriter(backups: backups).prepare(loaded: detail, declarations: try reencodedDeclarations(detail.json), target: .existingComponent(stepIndex: 0, componentIndex: 3))
                Issue.record("Expected a no-scope error")
            } catch let error as BlueprintWriter.WriteError {
                guard case .noScope = error else { Issue.record("Wrong error \(error)"); return }
            }
            #expect(backups.count == 0)
            let patched = apiRequests().contains { $0.method == "PATCH" }
            #expect(!patched)
        }

        @Test func scopeChangePatchesOnlyScopeAndVerifies() async throws {
            let state = ServerState(appSettingsBlueprintJSON)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                switch (request.method, request.path) {
                case ("GET", Self.path): return .json(200, state.text)
                case ("PATCH", Self.path):
                    state.applyPatch(request.body)
                    return MockResponse(status: 204, body: Data())
                default: return .json(404, "{}")
                }
            }
            let backups = BackupRecorder()
            let groups = ["11111111-2222-4333-8444-555555555555", "99999999-2222-4333-8444-555555555555"]
            let result = try await makeWriter(backups: backups).changeScope(loaded: loaded, deviceGroups: groups)
            #expect(result.isVerified, "\(result.problems)")
            #expect(backups.count == 1)
            #expect(result.previousGroups == ["11111111-2222-4333-8444-555555555555"])
            #expect(result.detail.scopeDeviceGroups == groups)
            let patch = try #require(apiRequests().first { $0.method == "PATCH" })
            #expect(patch.header("Content-Type") == "application/merge-patch+json")
            #expect(patch.bodyString == #"{"scope":{"deviceGroups":["11111111-2222-4333-8444-555555555555","99999999-2222-4333-8444-555555555555"]}}"#)
        }

        /// Unlike a steps write, a scope change is how an unscoped blueprint gets a scope.
        @Test func scopeChangeWorksOnUnscopedBlueprint() async throws {
            let unscoped = appSettingsBlueprintJSON.replacingOccurrences(of: #""scope":{"deviceGroups":["11111111-2222-4333-8444-555555555555"]}"#, with: #""scope":null"#)
            let state = ServerState(unscoped)
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                if request.method == "PATCH" {
                    state.applyPatch(request.body)
                    return MockResponse(status: 204, body: Data())
                }
                return .json(200, state.text)
            }
            let detail = try JamfPlatform.BlueprintDetail(data: Data(unscoped.utf8))
            let result = try await makeWriter().changeScope(loaded: detail, deviceGroups: ["g-1"])
            #expect(result.isVerified, "\(result.problems)")
            #expect(result.previousGroups.isEmpty)
            #expect(result.detail.scopeDeviceGroups == ["g-1"])
        }

        @Test func emptyScopeIsRefusedBeforeAnyRequest() async throws {
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, appSettingsBlueprintJSON) }
            let backups = BackupRecorder()
            do {
                _ = try await makeWriter(backups: backups).changeScope(loaded: loaded, deviceGroups: [])
                Issue.record("Expected an empty-scope error")
            } catch let error as BlueprintWriter.WriteError {
                guard case .emptyScope = error else { Issue.record("Wrong error \(error)"); return }
            }
            #expect(backups.count == 0)
            #expect(apiRequests().isEmpty)
        }

        @Test func scopeChangeStopsWhenBlueprintChanged() async throws {
            let changed = appSettingsBlueprintJSON.replacingOccurrences(of: "2026-10-02T09:30:00.222222Z", with: "2026-10-03T10:00:00Z")
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, changed) }
            let backups = BackupRecorder()
            await #expect(throws: BlueprintWriter.WriteError.self) {
                try await makeWriter(backups: backups).changeScope(loaded: loaded, deviceGroups: ["g-1"])
            }
            #expect(backups.count == 0)
            let patched = apiRequests().contains { $0.method == "PATCH" }
            #expect(!patched)
        }

        @Test func createPostsNameScopeAndStepsOnly() async throws {
            let created = appSettingsBlueprintJSON
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                if request.method == "POST" {
                    return .json(201, #"{"id":"\#(Self.id)","href":"https://eu.api.jamfcloud.com\#(Self.path)"}"#)
                }
                return .json(200, created)
            }
            let declarations = try reencodedDeclarations(loaded.json)
            _ = try await makeWriter().create(name: "iPad apps", description: nil, deviceGroups: ["g1"], stepName: "App Settings", activationPredicate: nil, declarations: declarations)
            let post = try #require(apiRequests().first { $0.method == "POST" })
            #expect(post.path == "/blueprints/v1/blueprints")
            let body = try LosslessJSON(data: post.body)
            #expect(body.objectValue?.keys == ["name", "scope", "steps"])
            #expect(body["scope"]?["deviceGroups"] == .array([.string("g1")]))
            #expect(!post.bodyString.contains("divisionId"))
        }

        @Test func createIsNotRetriedOn5xx() async {
            MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(503, "{}") }
            await #expect(throws: JamfPlatform.APIError.self) {
                try await makeWriter().create(name: "n", description: nil, deviceGroups: ["g"], stepName: "s", activationPredicate: nil,
                                              declarations: DeclarationEncoder.declarations(for: RuleSet()))
            }
            let posts = apiRequests().filter { $0.method == "POST" }
            #expect(posts.count == 1)
        }

        @Test func createRequiresADeviceGroup() async {
            MockURLProtocol.install { _ in .json(500, "{}") }
            await #expect(throws: JamfPlatform.APIError.self) {
                try await makeWriter().create(name: "n", description: nil, deviceGroups: [], stepName: "s", activationPredicate: nil,
                                              declarations: DeclarationEncoder.declarations(for: RuleSet()))
            }
            #expect(MockURLProtocol.requests.isEmpty)
        }
    }
}

/// A blueprint held by the mock server; PATCH applies merge-patch (steps replaced wholesale).
private final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var json: LosslessJSON

    init(_ text: String) { json = try! LosslessJSON(string: text) }

    var text: String { lock.withLock { json.serializedString() } }

    func applyPatch(_ body: Data) {
        lock.withLock {
            guard let patch = try? LosslessJSON(data: body) else { return }
            if let steps = patch["steps"] { json.setValue(steps, at: [.key("steps")]) }
            if let scope = patch["scope"] { json.setValue(scope, at: [.key("scope")]) }
            guard patch["steps"] != nil || patch["scope"] != nil else { return }
            json.setValue(.string("2026-10-23T08:00:00Z"), at: [.key("updated")])
            json.setValue(.object(LosslessJSON.Object(["state": .string("OUT_OF_DATE")])), at: [.key("deploymentState")])
        }
    }
}

/// Records backups instead of writing them to Application Support.
private final class BackupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var details: [JamfPlatform.BlueprintDetail] = []

    func record(_ detail: JamfPlatform.BlueprintDetail) { lock.withLock { details.append(detail) } }
    var count: Int { lock.withLock { details.count } }
}

@Suite("Backups")
struct BackupStoreTests {
    @Test func writesExactBytesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "as2b-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8))
        let date = Date(timeIntervalSince1970: 1_792_740_000)
        let first = try BackupStore.write(detail, date: date, root: root)
        let second = try BackupStore.write(detail, date: date, root: root)
        #expect(first != second, "A second backup at the same instant replaced the first")
        #expect(try Data(contentsOf: first) == Data(appSettingsBlueprintJSON.utf8))
        #expect(try Data(contentsOf: second) == Data(appSettingsBlueprintJSON.utf8))
        #expect(first.deletingLastPathComponent().lastPathComponent == detail.id)
    }
}

extension MockNetworkTests {
    @Suite("Deployment")
    struct DeploymentTests {
        private static let id = "0a1b2c3d-4444-4444-8444-0123456789ab"
        private static let path = "/blueprints/v1/blueprints/\(id)"
        private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)
        private static let previousStart = "2026-10-02T09:30:00.111111Z"

        private func blueprint(state: String, started: String, job: String) -> String {
            appSettingsBlueprintJSON.replacingOccurrences(
                of: #""deploymentState":{"state":"DEPLOYED","lastDeployment":{"started":"2026-10-02T09:30:00.111111Z","state":"SUCCEEDED"}}"#,
                with: #""deploymentState":{"state":"\#(state)","lastDeployment":{"started":"\#(started)","state":"\#(job)"}}"#
            )
        }

        private func makeBlueprints() -> JamfPlatform.Blueprints {
            JamfPlatform.Blueprints(client: try! PlatformAPIClient.make(
                credentials: PlatformCredentials(region: .eu, environmentID: testEnvironmentID, clientID: "id", clientSecret: "secret"),
                session: MockURLProtocol.makeSession(), log: nil, sleep: { _ in }
            ))
        }

        /// JTKit's watch, without real waits.
        private let poller = JamfPlatform.Poller(sleep: { _ in })

        @Test func followsTheNewDeploymentUntilItSucceeds() async throws {
            let gets = Counter()
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                switch (request.method, request.path) {
                case ("POST", Self.path + "/deploy"):
                    return MockResponse(status: 202, body: Data())
                case ("GET", Self.path + "/report"):
                    return .json(200, #"{"succeeded":0,"failed":0,"pending":0}"#)
                case ("GET", Self.path):
                    switch gets.next() {
                    // GET 1 is the fresh fetch of the previous start time before the POST.
                    // On the first poll the previous deployment is still the latest:
                    // not the one we started.
                    case 1, 2: return .json(200, appSettingsBlueprintJSON)
                    case 3: return .json(200, blueprint(state: "DEPLOYED", started: "2026-10-23T09:00:00Z", job: "DEPLOYING"))
                    default: return .json(200, blueprint(state: "DEPLOYED", started: "2026-10-23T09:00:00Z", job: "SUCCEEDED"))
                    }
                default:
                    return .json(404, "{}")
                }
            }
            let blueprints = makeBlueprints()
            let previous = try await blueprints.startDeployment(id: Self.id)
            #expect(previous == Self.previousStart)
            let updates = StatusRecorder()
            let outcome = try await blueprints.watchDeployment(id: Self.id, previousStart: previous, poller: poller) { updates.record($0) }
            let final = try #require(outcome.value)
            #expect(final.didSucceed)
            #expect(final.jobStarted == "2026-10-23T09:00:00Z")
            #expect(final.report == JamfPlatform.BlueprintReport(succeeded: 0, failed: 0, pending: 0))
            #expect(updates.jobStates == [nil, "DEPLOYING", "SUCCEEDED"])
            let posts = MockURLProtocol.requests.filter { $0.method == "POST" && $0.path != "/auth/token" }
            #expect(posts.map(\.path) == [Self.path + "/deploy"])
        }

        @Test func invalidBlueprintIsReportedNotRetried() async {
            MockURLProtocol.install { request in
                if request.path == "/auth/token" { return Self.token }
                // The blueprint is fetched before the POST; only the POST fails.
                if request.method == "GET" { return .json(200, appSettingsBlueprintJSON) }
                return .json(409, #"{"httpStatus":409,"errors":[{"code":"INVALID_BLUEPRINT","description":"Not valid for deployment"}]}"#)
            }
            let error = await #expect(throws: JamfPlatform.APIError.self) { _ = try await makeBlueprints().startDeployment(id: Self.id) }
            #expect(error?.status == 409)
            let posts = MockURLProtocol.requests.filter { $0.method == "POST" && $0.path != "/auth/token" }
            #expect(posts.count == 1)
        }
    }
}

@Suite("Deploy confirmation")
@MainActor
struct DeployModelTests {
    private func detail(declarations: String) throws -> JamfPlatform.BlueprintDetail {
        try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b1","name":"Mac apps","scope":{"deviceGroups":["g1"]},"deploymentState":{"state":"NOT_DEPLOYED"},"steps":[{"name":"S","components":[{"identifier":"com.jamf.ddm-strict","configuration":{"declarations":\#(declarations)}}]}]}"#.utf8))
    }

    @Test func allowListWithoutBaselineNeedsASecondConfirmation() throws {
        let model = DeployModel(app: AppModel(), detail: try detail(declarations: #"[{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":{"AllowedBinaries":[{"TeamID":"UBF8T346G9"}]}},"channelType":"SYSTEM"}]"#))
        #expect(model.allowListWarnings.count == 1)
        model.isConfirmed = true
        #expect(model.blockingReason != nil)
        model.acknowledgesAllowListRisk = true
        #expect(model.blockingReason == nil)
    }

    @Test func baselinePresentNeedsNoWarning() throws {
        let model = DeployModel(app: AppModel(), detail: try detail(declarations: #"[{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":{"AllowedBinaries":[{"TeamID":"*APPLE*","SigningState":"Apple"},{"TeamID":"UBF8T346G9"}],"AlwaysAllowManagedApps":true}},"channelType":"SYSTEM"}]"#))
        #expect(model.allowListWarnings.isEmpty)
        #expect(model.blockingReason != nil, "Nothing deploys before the confirmation is ticked")
        model.isConfirmed = true
        #expect(model.blockingReason == nil)
    }

    /// The watch takes up to 5 minutes, checking from 2 s growing to 10 s (was 4 s × 45).
    @Test func deploymentIsWatchedForFiveMinutes() throws {
        let model = DeployModel(app: AppModel(), detail: try detail(declarations: "[]"))
        #expect(model.poller.policy == .standard)
        #expect(model.poller.policy.timeLimit == .seconds(300))
        #expect(model.poller.policy.interval(afterCheck: 1) == .seconds(2))
    }

    @Test func unscopedBlueprintCannotBeDeployed() throws {
        let unscoped = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b2","name":"n","scope":null,"steps":[]}"#.utf8))
        let model = DeployModel(app: AppModel(), detail: unscoped)
        model.isConfirmed = true
        #expect(model.blockingReason?.contains("no device groups") == true)
    }
}

/// Records deployment updates from the monitor.
private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [JamfPlatform.DeploymentStatus] = []
    func record(_ status: JamfPlatform.DeploymentStatus) { lock.withLock { statuses.append(status) } }
    var jobStates: [String?] { lock.withLock { statuses.map(\.jobState) } }
}

import Foundation
import JTKit
import JTKitLiveCheck
import Testing
@testable import AppSettings2Blueprint

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1) and passes the credentials it read
// from the login Keychain. ⌘U skips them. The tenant is named by role only:
// jamf-test-a over the Jamf Platform API. Every request goes through
// JTKitLiveCheck's guarded network: creates only with the run's JTKTEST
// prefix, changes and deletes only of objects this run created.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

/// The allow-listed tenant as the checks use it.
struct LiveTenant: Sendable {
    static let role = "jamf-test-a"
    static let service = AllowList.Service.jamfPlatform

    let entry: AllowList.Entry
    let credentials: PlatformCredentials
    /// The app's own client (its allow-list included) on the guarded network:
    /// creates, writes and deploys exactly as the app does.
    let app: JamfPlatform.Client
    /// JTKit's client without the app's allow-list, still on the guarded
    /// network: the test device group and the removal of test objects,
    /// which the app itself never does.
    let api: JamfPlatform.Client

    init(run: LiveCheckRun) throws {
        entry = try run.entry(role: Self.role, service: Self.service)
        let region = try #require(JamfRegion(rawValue: entry.region ?? ""))
        credentials = PlatformCredentials(
            region: region, environmentID: try #require(entry.environmentID),
            clientID: try run.credential(Self.role, "client-id"),
            clientSecret: try run.credential(Self.role, "client-secret"),
            connectionName: "Live check")
        app = try PlatformAPIClient.make(credentials: credentials, session: run.network.session, log: nil)
        let secret = credentials.clientSecret
        api = try JamfPlatform.Client(
            connection: credentials.connection, secret: { secret },
            recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
    }

    var blueprints: JamfPlatform.Blueprints { JamfPlatform.Blueprints(client: app) }

    // MARK: The test device group

    /// An empty static computer group: never smart, never with members.
    func createEmptyStaticGroup(name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String](),
        ])
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfPlatform.Client.deviceGroupsPath,
                                                      body: body, contentType: "application/json"))
        let created = try LosslessJSON(data: response.data)
        return try #require(created["id"]?.stringValue, "The group create returned no id")
    }

    /// The group as Jamf has it, and its member list's total.
    func group(id: String) async throws -> (group: JamfPlatform.DeviceGroup?, members: Int?) {
        let path = "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        let group = JamfPlatform.DeviceGroup(json: try await api.json(path))
        let members = try await api.json(path + "/members")
        return (group, members["totalCount"]?.numberValue?.intValue ?? members["results"]?.arrayValue?.count)
    }

    // MARK: Test objects

    /// Every Blueprint and device group named as a test object.
    func testObjects(_ run: LiveCheckRun) async throws -> [(resource: String, id: String, name: String)] {
        let blueprints = try await self.blueprints.list().filter { run.isSweepable($0.name) }
        let groups = try await api.deviceGroups().filter { run.isSweepable($0.name) }
        return blueprints.map { ("blueprints", $0.id, $0.name) } + groups.map { ("device-groups", $0.id, $0.name) }
    }

    func delete(resource: String, id: String) async throws {
        let path = Ledger.Item(target: "", resource: resource, id: "", name: "").resource == "blueprints"
            ? "\(JamfPlatform.Blueprints.path)/\(JamfPlatform.pathSegment(id))"
            : "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        do {
            _ = try await api.send(HTTPRequest(method: "DELETE", path: path, repeating: .safe))
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            // Not counted from the answer: JTKit's read-back (0.12.6) marks it
            // removed only once the object is gone (Jamf answered 404 for a
            // group it still listed, 2026-10-30); a leftover fails the run.
        }
    }

    /// Deletes a test group once no Blueprint uses it any more. Jamf removes a
    /// deleted Blueprint in the background, and until then refuses the
    /// group's delete with 422 HAS_DEPENDENCIES (seen 2026-10-28); only that
    /// answer is retried, for up to two minutes.
    func deleteGroupWhenFree(id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                return try await delete(resource: "device-groups", id: id)
            } catch let error as JamfPlatform.APIError where error.status == 422 && error.hasDependencies && Date() < deadline {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Waits until a deleted Blueprint is gone (404), up to two minutes.
    func waitUntilBlueprintGone(id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            do {
                _ = try await blueprints.detail(id: id)
            } catch let error as JamfPlatform.APIError where error.status == 404 {
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
    }
}

private extension JamfPlatform.APIError {
    var hasDependencies: Bool {
        body?.errors.contains { $0.code == "HAS_DEPENDENCIES" } == true
    }
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and small reads (Blueprints and device groups), plus a count
    /// of left-over test objects (removed in stage 4). Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        do {
            let target = try LiveTenant(run: run)
            let leftovers = try await target.testObjects(run).count
            run.record(step: "sign in: \(LiveTenant.role)", passed: true, note: "\(leftovers) left-over test objects")
        } catch {
            run.record(step: "sign in: \(LiveTenant.role)", passed: false, note: String(describing: error))
            throw error
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: create, write, deploy, verify, remove", .enabled(if: live), .serialized)
struct LiveBlueprintTests {
    @Test func tenantA() async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(LiveTenant.role) else { return }
        let target = try LiveTenant(run: run)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        let step = { (name: String) in "\(LiveTenant.role): \(name)" }
        // Backups go to a folder of this run's, never the real Backups folder.
        let backups = FileManager.default.temporaryDirectory.appending(path: "as-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: backups) }
        var writer = BlueprintWriter(service: target.blueprints)
        writer.backup = { try BackupStore.write($0, root: backups) }

        // 1. An empty static test group, checked before anything is scoped to it.
        let groupName = "\(run.prefix) – Group"
        let groupID = try await target.createEmptyStaticGroup(name: groupName)
        let (group, members) = try await target.group(id: groupID)
        let isEmptyStatic = group?.groupType == .static && (group?.memberCount ?? 0) == 0 && members == 0
        run.record(step: step("create an empty static device group"), passed: isEmptyStatic,
                   note: "type \(group.map { $0.groupType.displayName } ?? "unknown"), \(group?.memberCount.map(String.init) ?? "?") members, member list \(members.map(String.init) ?? "?")")
        try #require(isEmptyStatic, "The test group isn't an empty static group; nothing is created or deployed")

        // 2. A test Blueprint with one app setting, created by the app's writer.
        let blueprintName = "\(run.prefix) – Blueprint"
        let created = try await writer.create(
            name: blueprintName, description: "Release check test object; removed after the run",
            deviceGroups: [groupID], stepName: "App Settings", activationPredicate: nil,
            declarations: DeclarationEncoder.declarations(for: Self.ruleSet(signingID: "com.example.jtktest.created")))
        #expect(created.created && created.isVerified, "\(created.problems)")
        run.record(step: step("create a Blueprint with one app setting"), passed: created.isVerified)
        // Only with `release-check.sh --fault fail-live-step`: fails with
        // objects on the tenant, so cleanup has to remove them.
        try run.injectFault("fail-live-step", at: step("failure after creating objects"))

        // 3. Write the app setting with the app's write path: fetch again,
        //    check, back up, PATCH the steps, read back and compare.
        let ruleSet = Self.ruleSet(signingID: "com.example.jtktest.written")
        let prepared = try await writer.prepare(loaded: created.detail, declarations: DeclarationEncoder.declarations(for: ruleSet),
                                                target: .existingComponent(stepIndex: 0, componentIndex: 0))
        let written = try await writer.commit(prepared)
        let backedUp = !BackupStore.backups(for: created.detail.id, root: backups).isEmpty
        #expect(written.isVerified && backedUp, "\(written.problems)")
        run.record(step: step("write the app setting"), passed: written.isVerified && backedUp)

        // 4. Deploy, only while the group still has no members.
        let (beforeDeploy, membersBeforeDeploy) = try await target.group(id: groupID)
        let stillEmpty = beforeDeploy?.groupType == .static && (beforeDeploy?.memberCount ?? 0) == 0 && membersBeforeDeploy == 0
        try #require(stillEmpty, "The test group has members now; not deploying")
        let previous = try await target.blueprints.startDeployment(id: created.detail.id)
        let outcome = try await target.blueprints.watchDeployment(id: created.detail.id, previousStart: previous)
        let deployed = outcome.isFinished && outcome.value?.didSucceed == true
        #expect(deployed, "deployment \(outcome.value?.jobState ?? "unknown")")
        run.record(step: step("deploy to the empty group"), passed: deployed, note: outcome.value?.jobState)

        // 5. Read back: exactly the written app setting, deployed.
        let readBack = try await target.blueprints.detail(id: created.detail.id)
        let location = try #require(AppSettingsLocator.locate(in: readBack.json).first)
        let declarations = readBack.json.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?.arrayValue ?? []
        let decoded = DeclarationDecoder.decode(declarations: declarations).ruleSet
        let matches = decoded.deniedBinaries.map(\.signingID) == ["com.example.jtktest.written"]
            && DeclarationEncoder.declarations(for: decoded) == DeclarationEncoder.declarations(for: ruleSet)
        let isDeployed = readBack.overview.deploymentState?.state == .deployed
        #expect(matches && isDeployed, "state \(String(describing: readBack.overview.deploymentState?.state))")
        run.record(step: step("read back the app setting, deployed"), passed: matches && isDeployed)

        // 6. Remove the Blueprint, then the group.
        try await target.delete(resource: "blueprints", id: created.detail.id)
        try await target.waitUntilBlueprintGone(id: created.detail.id)
        try await target.deleteGroupWhenFree(id: groupID)
        let left = try await target.testObjects(run).filter { $0.id == created.detail.id || $0.id == groupID }
        #expect(left.isEmpty, "still there: \(left.map(\.name))")
        run.record(step: step("remove the Blueprint and the group"), passed: left.isEmpty)
        #expect(run.ledger.outstanding.filter { $0.target == ledgerTarget }.isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }

    /// A macOS rule set with one app setting: a denied binary that matches
    /// no real app.
    static func ruleSet(signingID: String) -> RuleSet {
        var ruleSet = RuleSet()
        ruleSet.name = "JTKTEST"
        ruleSet.platform = .macOS
        ruleSet.deniedBinaries = [BinaryRule(teamID: "ZZJTKTEST1", signingID: signingID)]
        return ruleSet
    }
}

// MARK: Cleanup (every exit of stage 4)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the run's ledger still lists, then sweeps the tenant for
    /// anything still named as a test object. Blueprints go before groups (a
    /// group in a Blueprint's scope can't be removed). Fails if anything is left.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        where folder.hasPrefix("as-live-") {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: folder))
        }
        let target = try LiveTenant(run: run)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        for object in try await target.testObjects(run) {
            try run.adoptForSweep(role: LiveTenant.role, service: LiveTenant.service,
                                  resource: object.resource, id: object.id, name: object.name)
        }
        let blueprints = Ledger.Item(target: "", resource: "blueprints", id: "", name: "").resource
        let outstanding = run.ledger.outstanding.filter { $0.target == ledgerTarget }
        for item in outstanding.filter({ $0.resource == blueprints }) + outstanding.filter({ $0.resource != blueprints }) {
            do {
                if item.resource == blueprints {
                    try await target.delete(resource: item.resource, id: item.id)
                } else {
                    try await target.deleteGroupWhenFree(id: item.id)
                }
            } catch {
                run.record(step: "cleanup: \(item.resource) \(item.id)", passed: false, note: String(describing: error))
            }
        }
        let left = run.ledger.outstanding
        run.record(step: "cleanup", passed: left.isEmpty, note: left.isEmpty ? nil : "\(left.count) not removed")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
    }
}

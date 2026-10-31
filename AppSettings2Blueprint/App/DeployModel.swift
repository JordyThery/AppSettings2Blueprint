import Foundation
import JTKit
import Observation

/// Drives one deployment: the confirmation, a check that the Blueprint is still
/// what was confirmed, POST deploy, then JTKit's watch of the Blueprint and its
/// status report until the deployment finishes (checks from 2 s, growing to
/// 10 s, for up to 5 minutes).
@Observable
final class DeployModel {
    enum Phase {
        case confirming
        case deploying
        case watching(JamfPlatform.DeploymentStatus?)
        case finished(JamfPlatform.DeploymentStatus)
        /// Nothing was started: not sent, or refused by Jamf.
        case failed(String)
        /// The deploy request got no clear answer: it may have started.
        case uncertain(String)
        /// The deployment was started, but following its status failed.
        case watchFailed(String)
    }

    /// One scoped group, with its member count when the group list is loaded.
    struct GroupRow: Identifiable, Hashable {
        let id: String
        let name: String
        let memberCount: Int?
    }

    let app: AppModel
    private(set) var detail: JamfPlatform.BlueprintDetail
    var phase: Phase = .confirming
    var isConfirmed = false
    /// Second confirmation, required while an allow list lacks the recommended baseline.
    var acknowledgesAllowListRisk = false
    /// Set when the Blueprint changed in Jamf after the confirmation was shown;
    /// the confirmation then shows the new state and must be given again.
    private(set) var changeNotice: String?

    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// How the deployment is followed: JTKit's standard policy.
    @ObservationIgnored var poller = JamfPlatform.Poller()
    /// The connection this sheet was opened for; nothing is sent after it changed.
    private let connectionGeneration: Int

    init(app: AppModel, detail: JamfPlatform.BlueprintDetail) {
        self.app = app
        self.detail = detail
        connectionGeneration = app.connectionGeneration
    }

    var groups: [GroupRow] {
        detail.scopeDeviceGroups.map { id in
            let group = app.deviceGroups.first { $0.id == id }
            return GroupRow(id: id, name: app.groupName(id), memberCount: group?.memberCount)
        }
    }

    /// Nil when any group's member count is unknown.
    var deviceCount: Int? {
        let counts = groups.map(\.memberCount)
        guard !counts.contains(where: { $0 == nil }) else { return nil }
        return counts.compactMap { $0 }.reduce(0, +)
    }

    /// macOS allow lists in this Blueprint that lack AlwaysAllowManagedApps or the
    /// Apple-signed baseline, read from what is on the server (what gets deployed).
    /// Every component with App Settings counts, also those this app doesn't edit.
    var allowListWarnings: [String] {
        var seen = Set<[LosslessJSON.PathComponent]>()
        return detail.appSettingsLocations.compactMap { location in
            // one warning per component, however many declarations it holds
            guard seen.insert(location.componentPath).inserted else { return nil }
            let declarations = detail.json.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?.arrayValue ?? []
            let ruleSet = DeclarationDecoder.decode(declarations: declarations).ruleSet
            guard ruleSet.isMissingAllowListBaseline else { return nil }
            let missing = [
                ruleSet.alwaysAllowManagedApps == true ? nil : "AlwaysAllowManagedApps isn’t true",
                ruleSet.allowedBinaries.contains(where: \.isAppleBaseline) ? nil : "there’s no {\"TeamID\":\"*APPLE*\",\"SigningState\":\"Apple\"} entry",
            ].compactMap { $0 }
            return "Step \(location.stepIndex + 1), component \(location.componentIndex + 1): AllowedBinaries is set, but \(missing.joined(separator: " and ")). Binaries not listed, including Apple and managed apps, can be blocked."
        }
    }

    /// The editor holds unsaved changes for this Blueprint, which a deploy doesn’t include.
    var hasUnsavedEditorChanges: Bool {
        app.ruleSet.linkedBlueprint?.id == detail.id && app.ruleSet.isDirty
    }

    var blockingReason: String? {
        if detail.scopeDeviceGroups.isEmpty { return "The Blueprint has no device groups in scope." }
        if !isConfirmed { return "Check the confirmation box first." }
        if !allowListWarnings.isEmpty && !acknowledgesAllowListRisk { return "Acknowledge the allow list warning first." }
        return nil
    }

    func deploy() {
        guard blockingReason == nil else { return }
        phase = .deploying
        watchTask = Task { await performDeploy() }
    }

    func performDeploy() async {
        // The POST and the watch fail differently: before the POST succeeds
        // nothing was started; after it, the deployment runs on in Jamf.
        let blueprints: JamfPlatform.Blueprints
        let previous: String?
        do {
            guard app.connectionGeneration == connectionGeneration else { throw ConnectionChanged() }
            blueprints = try app.currentService()
            // Deploy only what was confirmed: another admin may have changed
            // the scope or the steps since the sheet opened.
            let latest = try await blueprints.detail(id: detail.id)
            guard Self.isUnchanged(confirmed: detail, latest: latest) else {
                showChanged(latest)
                return
            }
            // As JTKit's startDeployment: the last start before this one tells
            // the new deployment from the previous one.
            previous = latest.overview.deploymentState?.lastDeploymentStarted
            do {
                try await blueprints.deploy(id: detail.id)
            } catch let error as JamfPlatform.APIError where !BlueprintWriter.wasNotWritten(error) {
                phase = .uncertain("Jamf didn’t answer clearly, so the deployment may or may not have started: \(error.localizedDescription)\n\nCheck the Blueprint’s deployment state before deploying again.")
                app.reloadAfterUncertainWrite(id: detail.id)
                return
            }
        } catch is CancellationError {
            return
        } catch let error as JamfPlatform.APIError where error.status == 409 {
            phase = .failed("Jamf didn’t start the deployment: the Blueprint isn’t valid for deployment.\n\n\(error.localizedDescription)")
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .watching(nil)
        do {
            let outcome = try await blueprints.watchDeployment(id: detail.id, previousStart: previous, poller: poller) { status in
                await MainActor.run { self.phase = .watching(status) }
            }
            // a time-out keeps the last status seen; the deployment carries on in Jamf
            let final = outcome.value ?? JamfPlatform.DeploymentStatus()
            if let fresh = try? await blueprints.detail(id: detail.id) {
                detail = fresh
                app.storeDetail(fresh)
            }
            phase = .finished(final)
        } catch is CancellationError {
            return
        } catch {
            phase = .watchFailed(error.localizedDescription)
        }
    }

    /// The Blueprint as confirmed: same `updated`, steps and scope.
    static func isUnchanged(confirmed: JamfPlatform.BlueprintDetail, latest: JamfPlatform.BlueprintDetail) -> Bool {
        BlueprintWriter.isUnchanged(loaded: confirmed, latest: latest)
            && confirmed.scopeDeviceGroups == latest.scopeDeviceGroups
    }

    /// Back to the confirmation with the Blueprint as it is now, unconfirmed.
    private func showChanged(_ latest: JamfPlatform.BlueprintDetail) {
        detail = latest
        app.storeDetail(latest)
        isConfirmed = false
        acknowledgesAllowListRisk = false
        changeNotice = "“\(latest.overview.name)” was changed in Jamf after this confirmation opened, so nothing was deployed. Check the groups and warnings below, then confirm again."
        phase = .confirming
    }

    /// Stops polling; the deployment itself carries on in Jamf.
    func stopWatching() {
        watchTask?.cancel()
    }
}

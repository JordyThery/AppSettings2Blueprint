import Foundation
import JTKit
import Observation

/// Drives one deployment: the confirmation, POST deploy, then JTKit's watch of
/// the blueprint and its status report until the deployment finishes (checks
/// from 2 s, growing to 10 s, for up to 5 minutes).
@Observable
final class DeployModel {
    enum Phase {
        case confirming
        case deploying
        case watching(JamfPlatform.DeploymentStatus?)
        case finished(JamfPlatform.DeploymentStatus)
        /// The deploy POST itself failed; nothing was started.
        case failed(String)
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

    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// How the deployment is followed: JTKit's standard policy.
    @ObservationIgnored var poller = JamfPlatform.Poller()

    init(app: AppModel, detail: JamfPlatform.BlueprintDetail) {
        self.app = app
        self.detail = detail
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

    /// macOS allow lists in this blueprint that lack AlwaysAllowManagedApps or the
    /// Apple-signed baseline, read from what is on the server (what gets deployed).
    var allowListWarnings: [String] {
        detail.appSettingsLocations.filter(\.isStrictComponent).compactMap { location in
            let declarations = detail.json.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?.arrayValue ?? []
            let ruleSet = DeclarationDecoder.decode(declarations: declarations).ruleSet
            guard ruleSet.isMissingAllowListBaseline else { return nil }
            let missing = [
                ruleSet.alwaysAllowManagedApps == true ? nil : "AlwaysAllowManagedApps is not true",
                ruleSet.allowedBinaries.contains(where: \.isAppleBaseline) ? nil : "there is no {\"TeamID\":\"*APPLE*\",\"SigningState\":\"Apple\"} entry",
            ].compactMap { $0 }
            return "Step \(location.stepIndex + 1), component \(location.componentIndex + 1): AllowedBinaries is set, but \(missing.joined(separator: " and ")). Binaries not listed, including Apple and managed apps, can be blocked."
        }
    }

    /// The editor holds unsaved changes for this blueprint, which a deploy does not include.
    var hasUnsavedEditorChanges: Bool {
        app.ruleSet.linkedBlueprint?.id == detail.id && app.ruleSet.isDirty
    }

    var blockingReason: String? {
        if detail.scopeDeviceGroups.isEmpty { return "The blueprint has no device groups in scope." }
        if !isConfirmed { return "Tick the confirmation first." }
        if !allowListWarnings.isEmpty && !acknowledgesAllowListRisk { return "Acknowledge the allow-list warning first." }
        return nil
    }

    func deploy() {
        guard blockingReason == nil else { return }
        phase = .deploying
        watchTask = Task {
            // The POST and the watch fail differently: before the POST succeeds
            // nothing was started; after it, the deployment runs on in Jamf.
            let blueprints: JamfPlatform.Blueprints
            let previous: String?
            do {
                blueprints = try app.currentService()
                previous = try await blueprints.startDeployment(id: detail.id)
            } catch is CancellationError {
                return
            } catch let error as JamfPlatform.APIError {
                if error.status == 409 {
                    phase = .failed("Jamf did not start the deployment: the blueprint is not valid for deployment.\n\n\(error.localizedDescription)")
                } else {
                    phase = .failed(error.localizedDescription)
                }
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
    }

    /// Stops polling; the deployment itself carries on in Jamf.
    func stopWatching() {
        watchTask?.cancel()
    }
}

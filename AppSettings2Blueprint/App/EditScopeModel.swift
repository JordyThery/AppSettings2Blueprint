import Foundation
import JTKit
import Observation

/// Drives Edit Scope: choose a blueprint's device groups, then PATCH the scope
/// only, after a concurrency check and a backup, and verify the read-back.
@Observable
final class EditScopeModel {
    enum Phase {
        case editing
        case saving
        case done(ScopeChangeResult)
        case failed(String)
    }

    /// One row: a group from the device group list, or a scoped ID the list does not contain.
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String?
        let memberCount: Int?
    }

    let app: AppModel
    let detail: JamfPlatform.BlueprintDetail
    var selected: Set<String>
    var searchText = ""
    var phase: Phase = .editing
    /// Required when groups are removed from a blueprint that has been deployed.
    var acknowledgesRemoval = false

    init(app: AppModel, detail: JamfPlatform.BlueprintDetail) {
        self.app = app
        self.detail = detail
        selected = Set(detail.scopeDeviceGroups)
    }

    var currentGroups: [String] { detail.scopeDeviceGroups }

    /// Groups in scope first (in their current order), then the rest by name.
    var rows: [Row] {
        let known = Dictionary(app.deviceGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func row(_ id: String) -> Row {
            if let group = known[id] {
                return Row(id: id, name: group.name,
                           detail: "\(group.deviceType.displayName) · \(group.groupType.displayName)",
                           memberCount: group.memberCount)
            }
            return Row(id: id, name: id, detail: "Not in the device group list", memberCount: nil)
        }
        let scoped = currentGroups.map(row)
        let others = app.deviceGroups
            .filter { !currentGroups.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { row($0.id) }
        let all = scoped + others
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    /// The new scope: kept groups in their current order, then additions by name.
    var newGroups: [String] {
        let kept = currentGroups.filter(selected.contains)
        let added = app.deviceGroups
            .filter { selected.contains($0.id) && !currentGroups.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
        return kept + added
    }

    var addedGroups: [String] { newGroups.filter { !currentGroups.contains($0) } }
    var removedGroups: [String] { currentGroups.filter { !selected.contains($0) } }
    var hasChanges: Bool { !addedGroups.isEmpty || !removedGroups.isEmpty }

    /// Removing groups from a deployed blueprint takes its settings off those
    /// devices at the next deployment.
    var removalNeedsAcknowledgement: Bool {
        guard !removedGroups.isEmpty, let state = detail.overview.deploymentState?.state else { return false }
        return state != .notDeployed
    }

    func memberCount(_ id: String) -> Int? {
        app.deviceGroups.first { $0.id == id }?.memberCount
    }

    var blockingReason: String? {
        if app.isReadOnly(detail) { return "This blueprint is assigned to a division and is read-only." }
        if app.deviceGroups.isEmpty { return app.isLoadingDeviceGroups ? "Loading device groups…" : "No device groups are available." }
        if selected.isEmpty { return "Choose at least one device group." }
        if !hasChanges { return "The scope is unchanged." }
        if removalNeedsAcknowledgement && !acknowledgesRemoval { return "Acknowledge the removed groups first." }
        return nil
    }

    func save() {
        guard blockingReason == nil else { return }
        let groups = newGroups
        phase = .saving
        Task {
            do {
                let writer = try app.makeWriter()
                let result = try await writer.changeScope(loaded: detail, deviceGroups: groups)
                app.storeDetail(result.detail)
                phase = .done(result)
            } catch {
                if case BlueprintWriter.WriteError.readOnly = error { app.readOnlyBlueprintIDs.insert(detail.id) }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

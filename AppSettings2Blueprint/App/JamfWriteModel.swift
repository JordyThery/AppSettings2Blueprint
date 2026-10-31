import Foundation
import JTKit
import Observation

/// Drives "Write to Jamf": choose a target, prepare (concurrency check, backup,
/// new steps), review the diff, then PATCH or POST and verify the read-back.
@Observable
final class JamfWriteModel {
    enum Mode: String, CaseIterable, Identifiable {
        case existing = "Existing Blueprint"
        case new = "New Blueprint"
        var id: String { rawValue }
    }

    /// Where the component goes in an existing blueprint, as picked in the sheet.
    enum Placement: Hashable {
        case replaceExisting(stepIndex: Int, componentIndex: Int)
        case appendToStep(Int)
        case newStep
    }

    enum Phase {
        case choosing
        case preparing
        case review(PreparedWrite)
        case writing
        case done(WriteResult)
        /// Nothing was sent, or Jamf refused it: the choice can be changed and tried again.
        case failed(String)
        /// The write may have reached Jamf (it succeeded but couldn’t be read
        /// back, or got no clear answer). There is no way back to the same
        /// action: a second create would make a second Blueprint.
        case uncertain(String)
    }

    let app: AppModel
    var mode: Mode = .existing
    var phase: Phase = .choosing
    /// The connection this sheet was opened for; nothing is sent after it changed.
    private let connectionGeneration: Int

    // Existing blueprint
    var selectedBlueprintID: String? {
        didSet { if oldValue != selectedBlueprintID { placement = nil } }
    }
    var placement: Placement?

    // New blueprint
    var newName = ""
    var newDescription = ""
    var selectedGroupIDs: Set<String> = []

    // Step options (new blueprint, or a new step in an existing one)
    var stepName = "App Settings"
    var usesActivationPredicate = false
    var activationPredicate = ""

    init(app: AppModel) {
        self.app = app
        connectionGeneration = app.connectionGeneration
        let document = app.ruleSet
        selectedBlueprintID = document.linkedBlueprint?.id
        newName = document.ruleSet.name
        activationPredicate = Self.suggestedPredicate(for: document.ruleSet.platform)
        listDidChange()
    }

    /// New Blueprint is the default only once the list is known to be empty;
    /// before it has loaded, Existing is shown, so a tenant's Blueprints aren't
    /// skipped in favor of a duplicate.
    func listDidChange() {
        guard case .choosing = phase, app.ruleSet.linkedBlueprint == nil, canCreateBlueprints,
              case .finished = app.listState, app.overviews.isEmpty else { return }
        mode = .new
    }

    /// A new Blueprint needs device groups, which a Jamf School environment
    /// doesn’t list; there, only existing Blueprints can be written.
    var canCreateBlueprints: Bool { !app.isJamfSchool }

    /// One Blueprint per platform is the default; a predicate lets one Blueprint
    /// hold both an iPadOS and a macOS rule set.
    static func suggestedPredicate(for platform: RulePlatform) -> String {
        switch platform {
        case .iOS: "@status(device.operating-system.family) == 'iPadOS'"
        case .macOS: "@status(device.operating-system.family) == 'macOS'"
        }
    }

    var declarations: [LosslessJSON] { DeclarationEncoder.declarations(for: app.ruleSet.ruleSet) }

    var selectedDetail: JamfPlatform.BlueprintDetail? { selectedBlueprintID.flatMap { app.details[$0] } }

    var predicate: String? {
        let text = activationPredicate.trimmingCharacters(in: .whitespacesAndNewlines)
        return usesActivationPredicate && !text.isEmpty ? text : nil
    }

    /// The placement to use: the one picked, else the component the rule set was
    /// loaded from, else the locator's default.
    func effectivePlacement(for detail: JamfPlatform.BlueprintDetail) -> Placement {
        if let placement { return placement }
        if let linked = app.ruleSet.linkedBlueprint, linked.id == detail.id,
           let step = linked.stepIndex, let component = linked.componentIndex,
           detail.appSettingsLocations.contains(where: {
               $0.isStrictComponent && $0.stepIndex == step && $0.componentIndex == component
           }) {
            return .replaceExisting(stepIndex: step, componentIndex: component)
        }
        switch AppSettingsLocator.defaultTarget(in: detail.json) {
        case let .existingComponent(step, component): return .replaceExisting(stepIndex: step, componentIndex: component)
        case let .newComponent(step): return .appendToStep(step)
        case .newStep: return .newStep
        }
    }

    func target(for placement: Placement) -> AppSettingsTarget {
        switch placement {
        case let .replaceExisting(step, component): .existingComponent(stepIndex: step, componentIndex: component)
        case let .appendToStep(step): .newComponent(stepIndex: step)
        case .newStep: .newStep(name: stepName.isEmpty ? "App Settings" : stepName, activationPredicate: predicate)
        }
    }

    /// Why the current choice can’t continue yet, or nil.
    var blockingReason: String? {
        if app.ruleSet.hasErrors { return "Fix the rule set’s errors first." }
        switch mode {
        case .existing:
            guard let id = selectedBlueprintID else { return "Choose a Blueprint." }
            guard let detail = selectedDetail else {
                return app.detailErrors[id] == nil ? "Loading the Blueprint…" : "The Blueprint couldn’t be loaded."
            }
            if app.isReadOnly(detail) { return Self.divisionText }
            if detail.scopeDeviceGroups.isEmpty { return Self.noScopeText(isJamfSchool: app.isJamfSchool) }
            if case let .appendToStep(step) = effectivePlacement(for: detail),
               let count = detail.steps?[step]?["components"]?.arrayValue?.count,
               count >= AppSettingsLocator.maxComponentsPerStep {
                return "Step \(step + 1) already has \(count) components, the most a step can hold."
            }
            return nil
        case .new:
            if !canCreateBlueprints { return "Create the Blueprint in Jamf School, then write to it here." }
            if newName.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
            if selectedGroupIDs.isEmpty { return "Choose at least one device group." }
            return nil
        }
    }

    /// Whether Return presses the sheet's main button. Review Changes… only
    /// prepares; Create Blueprint writes at once, with no review, so Return in
    /// the Name field must not press it.
    var primaryButtonIsDefault: Bool { mode == .existing }

    /// JTKit's sentence for a division-assigned Blueprint.
    static let divisionText = "This Blueprint is assigned to a division and can’t be changed through the API."

    /// The same sentence wherever a Blueprint without scope is refused.
    static func noScopeText(isJamfSchool: Bool) -> String {
        isJamfSchool
            ? "This Blueprint has no device groups in scope. The Platform API rejects changes until it has one; set the scope in Jamf School first."
            : "This Blueprint has no device groups in scope. The Platform API rejects changes until it has one; set the scope with Edit Scope… first."
    }

    /// Other Blueprints with App Settings that share a device group with the target.
    /// Allowed* lists from several declarations intersect and Denied* lists combine
    /// on the device, so these change the effective result.
    var overlappingBlueprints: [JamfPlatform.BlueprintDetail] {
        let groups: Set<String> = switch mode {
        case .existing: Set(selectedDetail?.scopeDeviceGroups ?? [])
        case .new: selectedGroupIDs
        }
        guard !groups.isEmpty else { return [] }
        return app.details.values
            .filter { $0.id != selectedBlueprintID && $0.containsAppSettings && !groups.isDisjoint(with: $0.scopeDeviceGroups) }
            .sorted { $0.overview.name < $1.overview.name }
    }

    // MARK: Actions

    /// For an existing Blueprint: concurrency check, backup and the new steps,
    /// then the review. A new Blueprint is created right away: there is nothing
    /// on the server to diff against.
    func prepare() {
        guard blockingReason == nil else { return }
        phase = .preparing
        Task { await performPrepare() }
    }

    func performPrepare() async {
        let createPath: [LosslessJSON.PathComponent] = [.key("steps"), .index(0), .key("components"), .index(0)]
        let name = newName.trimmingCharacters(in: .whitespaces)
        do {
            let writer = try makeWriter()
            switch mode {
            case .existing:
                guard let loaded = selectedDetail else {
                    phase = .failed("The Blueprint is no longer loaded. Close this sheet and reload the list.")
                    return
                }
                let prepared = try await writer.prepare(
                    loaded: loaded, declarations: declarations, target: target(for: effectivePlacement(for: loaded))
                )
                app.storeDetail(prepared.latest)
                phase = .review(prepared)
            case .new:
                phase = .writing
                let result = try await writer.create(
                    name: name,
                    description: newDescription.isEmpty ? nil : newDescription,
                    deviceGroups: Array(selectedGroupIDs).sorted(),
                    stepName: stepName.isEmpty ? "App Settings" : stepName,
                    activationPredicate: predicate,
                    declarations: declarations
                )
                finish(result, componentPath: createPath)
            }
        } catch {
            fail(error, componentPath: mode == .new ? createPath : nil)
        }
    }

    /// After the review: PATCH and verify.
    func commit(_ prepared: PreparedWrite) {
        phase = .writing
        Task { await performCommit(prepared) }
    }

    func performCommit(_ prepared: PreparedWrite) async {
        do {
            finish(try await makeWriter().commit(prepared), componentPath: prepared.edit.componentPath)
        } catch {
            fail(error, componentPath: prepared.edit.componentPath)
        }
    }

    func backToChoosing() {
        phase = .choosing
    }

    private func makeWriter() throws -> BlueprintWriter {
        guard app.connectionGeneration == connectionGeneration else { throw ConnectionChanged() }
        return try app.makeWriter()
    }

    private func finish(_ result: WriteResult, componentPath: [LosslessJSON.PathComponent]) {
        app.storeDetail(result.detail)
        link(id: result.detail.id, name: result.detail.overview.name, componentPath: componentPath)
        phase = .done(result)
    }

    /// The rule set now lives in this Blueprint: later writes go to the same
    /// component, and it counts as saved.
    private func link(id: String, name: String, componentPath: [LosslessJSON.PathComponent]) {
        var stepIndex: Int?
        var componentIndex: Int?
        if componentPath.count >= 4,
           case let .index(step) = componentPath[1],
           case let .index(component) = componentPath[3] {
            stepIndex = step
            componentIndex = component
        }
        app.ruleSet.linkedBlueprint = LinkedBlueprint(id: id, name: name, stepIndex: stepIndex, componentIndex: componentIndex)
        app.ruleSet.markSaved()
        mode = .existing
        selectedBlueprintID = id
    }

    private func fail(_ error: Error, componentPath: [LosslessJSON.PathComponent]?) {
        if case BlueprintWriter.WriteError.readOnly = error, let id = selectedBlueprintID {
            app.readOnlyBlueprintIDs.insert(id)
        }
        if let writeError = error as? BlueprintWriter.WriteError, writeError.mayHaveWritten {
            switch writeError {
            case let .notVerified(name, id, _, _):
                // The write succeeded: link the rule set as after a verified write,
                // and fetch the Blueprint again instead of trusting the cached copy.
                if let componentPath { link(id: id, name: name, componentPath: componentPath) }
                app.reloadAfterUncertainWrite(id: id)
            default:
                app.reloadAfterUncertainWrite(id: mode == .existing ? selectedBlueprintID : nil)
            }
            phase = .uncertain(writeError.localizedDescription)
            return
        }
        if error is CancellationError { phase = .choosing; return }
        phase = .failed(error.localizedDescription)
    }
}

/// The connection was switched while a sheet was open.
struct ConnectionChanged: Error, LocalizedError {
    var errorDescription: String? {
        "The connection changed while this sheet was open, so nothing was sent. Close it and start again."
    }
}

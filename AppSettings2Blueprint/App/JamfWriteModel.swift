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
        case failed(String)
    }

    let app: AppModel
    var mode: Mode = .existing
    var phase: Phase = .choosing

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
        let document = app.ruleSet
        selectedBlueprintID = document.linkedBlueprint?.id
        newName = document.ruleSet.name
        activationPredicate = Self.suggestedPredicate(for: document.ruleSet.platform)
        if document.linkedBlueprint == nil && !app.isJamfSchool { mode = app.overviews.isEmpty ? .new : .existing }
    }

    /// A new blueprint needs device groups, which a Jamf School environment does
    /// not list; there, only existing blueprints can be written.
    var canCreateBlueprints: Bool { !app.isJamfSchool }

    /// One Blueprint per platform is the default; a predicate lets one blueprint
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

    /// Why the current choice cannot continue yet, or nil.
    var blockingReason: String? {
        if app.ruleSet.hasErrors { return "Fix the rule set's errors first." }
        switch mode {
        case .existing:
            guard let detail = selectedDetail else { return "Choose a blueprint." }
            if app.isReadOnly(detail) { return "This blueprint is assigned to a division and is read-only." }
            if detail.scopeDeviceGroups.isEmpty {
                return app.isJamfSchool
                    ? "This blueprint has no device groups in scope; the API rejects changes until it has one. Set its scope in Jamf School first."
                    : "This blueprint has no device groups in scope; the API rejects changes until it has one. Set it with Edit Scope… first."
            }
            if case let .appendToStep(step) = effectivePlacement(for: detail),
               let count = detail.steps?[step]?["components"]?.arrayValue?.count,
               count >= AppSettingsLocator.maxComponentsPerStep {
                return "Step \(step + 1) already has \(count) components, the most a step can hold."
            }
            return nil
        case .new:
            if !canCreateBlueprints { return "Create the blueprint in Jamf School, then write to it here." }
            if newName.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
            if selectedGroupIDs.isEmpty { return "Choose at least one device group." }
            return nil
        }
    }

    /// Other blueprints with App Settings that share a device group with the target.
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

    /// Steps 1–4 for an existing blueprint. A new blueprint is created right away:
    /// there is nothing on the server to diff against.
    func prepare() {
        guard blockingReason == nil else { return }
        phase = .preparing
        Task {
            do {
                switch mode {
                case .existing:
                    guard let loaded = selectedDetail else {
                        phase = .failed("The blueprint is no longer loaded. Close this sheet and reload the list.")
                        return
                    }
                    let writer = try makeWriter()
                    let prepared = try await writer.prepare(
                        loaded: loaded, declarations: declarations, target: target(for: effectivePlacement(for: loaded))
                    )
                    app.storeDetail(prepared.latest)
                    phase = .review(prepared)
                case .new:
                    phase = .writing
                    let result = try await makeWriter().create(
                        name: newName.trimmingCharacters(in: .whitespaces),
                        description: newDescription.isEmpty ? nil : newDescription,
                        deviceGroups: Array(selectedGroupIDs).sorted(),
                        stepName: stepName.isEmpty ? "App Settings" : stepName,
                        activationPredicate: predicate,
                        declarations: declarations
                    )
                    finish(result, componentPath: [.key("steps"), .index(0), .key("components"), .index(0)])
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Steps 5–7: PATCH and verify.
    func commit(_ prepared: PreparedWrite) {
        phase = .writing
        Task {
            do {
                finish(try await makeWriter().commit(prepared), componentPath: prepared.edit.componentPath)
            } catch {
                fail(error)
            }
        }
    }

    func backToChoosing() {
        phase = .choosing
    }

    private func makeWriter() throws -> BlueprintWriter {
        try app.makeWriter()
    }

    private func finish(_ result: WriteResult, componentPath: [LosslessJSON.PathComponent]) {
        app.storeDetail(result.detail)
        var stepIndex: Int?
        var componentIndex: Int?
        if componentPath.count >= 4,
           case let .index(step) = componentPath[1],
           case let .index(component) = componentPath[3] {
            stepIndex = step
            componentIndex = component
        }
        app.ruleSet.linkedBlueprint = LinkedBlueprint(
            id: result.detail.id, name: result.detail.overview.name,
            stepIndex: stepIndex, componentIndex: componentIndex
        )
        app.ruleSet.markSaved()
        selectedBlueprintID = result.detail.id
        phase = .done(result)
    }

    private func fail(_ error: Error) {
        if case BlueprintWriter.WriteError.readOnly = error, let id = selectedBlueprintID {
            app.readOnlyBlueprintIDs.insert(id)
        }
        if error is CancellationError { phase = .choosing; return }
        phase = .failed(error.localizedDescription)
    }
}

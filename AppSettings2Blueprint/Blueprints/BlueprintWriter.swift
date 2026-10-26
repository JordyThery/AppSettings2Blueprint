import Foundation
import JTKit

/// A write that has been checked and backed up, waiting for review.
nonisolated struct PreparedWrite: Sendable {
    /// The blueprint as fetched right before the backup.
    let latest: JamfPlatform.BlueprintDetail
    let edit: AppSettingsEdit
    let backupURL: URL
    /// The exact PATCH body: `{"steps": [...]}`.
    let patchBody: Data

    var blueprintID: String { latest.id }
    var name: String { latest.overview.name }

    /// The component before and after, as a line diff of pretty-printed JSON.
    var diff: [DiffLine] {
        TextDiff.lines(
            from: edit.oldComponent?.serializedString(pretty: true) ?? "",
            to: edit.newComponent.serializedString(pretty: true)
        )
    }
}

/// What the read-back after a write showed.
nonisolated struct WriteResult: Sendable {
    let detail: JamfPlatform.BlueprintDetail
    /// The written component, as the server returned it.
    let readBackComponent: LosslessJSON?
    /// Empty when the server returned exactly what was sent (allowing for key
    /// order and number formatting).
    let problems: [String]
    let created: Bool

    var isVerified: Bool { problems.isEmpty }
}

/// What the read-back after a scope change showed.
nonisolated struct ScopeChangeResult: Sendable {
    let detail: JamfPlatform.BlueprintDetail
    let previousGroups: [String]
    let backupURL: URL
    /// Empty when the scope came back as sent and the steps are unchanged.
    let problems: [String]

    var isVerified: Bool { problems.isEmpty }
}

/// Writes a rule set into a blueprint: re-GET and compare, back up, build the new
/// steps, review, PATCH `{"steps": [...]}` only, GET again and verify. Or creates
/// a new blueprint with POST. Never sends divisionId; never deletes or undeploys.
nonisolated struct BlueprintWriter: Sendable {
    enum WriteError: Error, LocalizedError {
        case changedOnServer(name: String, loaded: String?, now: String?)
        case readOnly(name: String)
        case noScope(name: String)
        case emptyScope
        case notAnArray

        var errorDescription: String? {
            switch self {
            case let .changedOnServer(name, loaded, now):
                "“\(name)” was modified after it was loaded (loaded: \(loaded ?? "unknown"), now: \(now ?? "unknown")). Nothing was written. Reload the blueprint and try again."
            case let .noScope(name):
                "“\(name)” has no device groups in scope. The Platform API rejects changes to a blueprint without a scope (400 NotBlank: scopeId), even ones that only send steps. Add a device group to its scope in Jamf, then try again. Nothing was written."
            case let .readOnly(name):
                "“\(name)” is assigned to a division and cannot be changed through the API. Nothing was written."
            case .emptyScope:
                "A blueprint's scope needs at least one device group. Nothing was written."
            case .notAnArray:
                "The new steps are not an array; refusing to send a partial PATCH."
            }
        }
    }

    let service: JamfPlatform.Blueprints
    /// Writes the full blueprint JSON before a PATCH; injectable for tests.
    var backup: @Sendable (JamfPlatform.BlueprintDetail) throws -> URL = { try BackupStore.write($0) }

    // MARK: Existing blueprint

    /// Steps 1–3 and the material for step 4: concurrency check, backup, new steps.
    func prepare(loaded: JamfPlatform.BlueprintDetail, declarations: [LosslessJSON], target: AppSettingsTarget) async throws -> PreparedWrite {
        let latest = try await service.detail(id: loaded.id)
        try checkUnchanged(loaded: loaded, latest: latest)
        if latest.isDivisionLocked { throw WriteError.readOnly(name: latest.overview.name) }
        if latest.scopeDeviceGroups.isEmpty { throw WriteError.noScope(name: latest.overview.name) }
        let backupURL = try backup(latest)
        let edit = try AppSettingsLocator.edit(blueprint: latest.json, declarations: declarations, target: target)
        guard edit.steps.arrayValue != nil else { throw WriteError.notAnArray }
        let body = LosslessJSON.object(LosslessJSON.Object(["steps": edit.steps])).serialized()
        return PreparedWrite(latest: latest, edit: edit, backupURL: backupURL, patchBody: body)
    }

    /// Steps 5–7: a last concurrency check, PATCH, GET and verify.
    func commit(_ prepared: PreparedWrite) async throws -> WriteResult {
        // The review can take a while; make sure nothing changed in the meantime.
        let current = try await service.detail(id: prepared.blueprintID)
        try checkUnchanged(loaded: prepared.latest, latest: current)
        do {
            try await service.patchSteps(id: prepared.blueprintID, steps: prepared.edit.steps)
        } catch let error as JamfPlatformError where error.hasCode(.divisionPatchNotAllowed) {
            throw WriteError.readOnly(name: prepared.name)
        }
        let readBack = try await service.detail(id: prepared.blueprintID)
        return verify(readBack: readBack, sentSteps: prepared.edit.steps, componentPath: prepared.edit.componentPath, created: false)
    }

    // MARK: Restore

    /// PATCHes the steps of a backup back, after the same concurrency check and a
    /// fresh backup of the current state.
    func restore(_ saved: BlueprintBackup, loaded: JamfPlatform.BlueprintDetail) async throws -> WriteResult {
        let backupDetail = try BackupStore.load(saved)
        guard let steps = backupDetail.steps, steps.arrayValue != nil else { throw WriteError.notAnArray }
        let latest = try await service.detail(id: loaded.id)
        try checkUnchanged(loaded: loaded, latest: latest)
        if latest.isDivisionLocked { throw WriteError.readOnly(name: latest.overview.name) }
        if latest.scopeDeviceGroups.isEmpty { throw WriteError.noScope(name: latest.overview.name) }
        _ = try backup(latest)
        do {
            try await service.patchSteps(id: loaded.id, steps: steps)
        } catch let error as JamfPlatformError where error.hasCode(.divisionPatchNotAllowed) {
            throw WriteError.readOnly(name: latest.overview.name)
        }
        let readBack = try await service.detail(id: loaded.id)
        let same = (readBack.steps ?? .null).isSemanticallyEqual(to: steps)
        return WriteResult(
            detail: readBack, readBackComponent: nil,
            problems: same ? [] : ["The steps the server returned differ from the backup's steps."],
            created: false
        )
    }

    // MARK: Scope

    /// Changes a blueprint's device groups: concurrency check, backup, PATCH
    /// `{"scope": …}` only, GET and verify that the scope matches and the steps
    /// are untouched. Unlike a steps write, this works on an unscoped blueprint.
    func changeScope(loaded: JamfPlatform.BlueprintDetail, deviceGroups: [String]) async throws -> ScopeChangeResult {
        guard !deviceGroups.isEmpty else { throw WriteError.emptyScope }
        let latest = try await service.detail(id: loaded.id)
        try checkUnchanged(loaded: loaded, latest: latest)
        if latest.isDivisionLocked { throw WriteError.readOnly(name: latest.overview.name) }
        let backupURL = try backup(latest)
        do {
            try await service.patchScope(id: loaded.id, deviceGroups: deviceGroups)
        } catch let error as JamfPlatformError where error.hasCode(.divisionPatchNotAllowed) {
            throw WriteError.readOnly(name: latest.overview.name)
        }
        let readBack = try await service.detail(id: loaded.id)
        var problems: [String] = []
        if Set(readBack.scopeDeviceGroups) != Set(deviceGroups) {
            problems.append("The scope the server returned (\(readBack.scopeDeviceGroups.joined(separator: ", "))) differs from what was sent (\(deviceGroups.joined(separator: ", "))).")
        }
        if !(readBack.steps ?? .null).isSemanticallyEqual(to: latest.steps ?? .null) {
            problems.append("The blueprint's steps changed, although only the scope was sent. Compare with the backup.")
        }
        return ScopeChangeResult(
            detail: readBack, previousGroups: latest.scopeDeviceGroups, backupURL: backupURL, problems: problems
        )
    }

    // MARK: New blueprint

    /// POST a new blueprint with one step holding the component, then GET and verify.
    func create(
        name: String,
        description: String?,
        deviceGroups: [String],
        stepName: String,
        activationPredicate: String?,
        declarations: [LosslessJSON]
    ) async throws -> WriteResult {
        let component = AppSettingsLocator.component(declarations: declarations)
        let step = AppSettingsLocator.step(name: stepName, components: [component], activationPredicate: activationPredicate)
        let id = try await service.create(name: name, description: description, deviceGroups: deviceGroups, steps: [step])
        let readBack = try await service.detail(id: id)
        return verify(
            readBack: readBack, sentSteps: .array([step]),
            componentPath: [.key("steps"), .index(0), .key("components"), .index(0)], created: true
        )
    }

    // MARK: Checks

    /// The `updated` timestamp and the steps must both be as loaded.
    func checkUnchanged(loaded: JamfPlatform.BlueprintDetail, latest: JamfPlatform.BlueprintDetail) throws {
        let sameSteps = (loaded.steps ?? .null) == (latest.steps ?? .null)
        guard loaded.isUnchanged(in: latest), sameSteps else {
            throw WriteError.changedOnServer(name: latest.overview.name, loaded: loaded.overview.updated, now: latest.overview.updated)
        }
    }

    /// Compares the read-back with what was sent: the written component must match,
    /// and every other component must be unchanged. Key order and number
    /// formatting are allowed to differ (the server may canonicalise them).
    func verify(readBack: JamfPlatform.BlueprintDetail, sentSteps: LosslessJSON, componentPath: [LosslessJSON.PathComponent], created: Bool) -> WriteResult {
        var problems: [String] = []
        let relative = Array(componentPath.dropFirst())  // drop .key("steps")
        let sentComponent = sentSteps.value(at: relative)
        let readComponent = readBack.json.value(at: componentPath)
        if let sentComponent, let readComponent {
            if !readComponent.isSemanticallyEqual(to: sentComponent) {
                problems.append("The App Settings component the server returned differs from what was sent. Compare them below before deploying.")
            }
        } else {
            problems.append("The written component was not found at \(componentPath.pathString) in the read-back.")
        }

        let sent = sentSteps.arrayValue ?? []
        let read = readBack.steps?.arrayValue ?? []
        if sent.count != read.count {
            problems.append("The blueprint has \(read.count) steps after the write; \(sent.count) were sent.")
        } else {
            var changed = 0
            for (stepIndex, (sentStep, readStep)) in zip(sent, read).enumerated() {
                // A step's own fields (name, activationPredicate, …) must come
                // back as sent; a dropped predicate would change who gets the rules.
                for member in sentStep.objectValue?.members ?? [] where member.key != "components" {
                    let returned = readStep[member.key]
                    if returned == nil || returned?.isSemanticallyEqual(to: member.value) == false {
                        problems.append("Step \(stepIndex + 1)'s \(member.key) came back different from what was sent.")
                    }
                }
                let sentComponents = sentStep["components"]?.arrayValue ?? []
                let readComponents = readStep["components"]?.arrayValue ?? []
                guard sentComponents.count == readComponents.count else {
                    problems.append("Step \(stepIndex + 1) has \(readComponents.count) components after the write; \(sentComponents.count) were sent.")
                    continue
                }
                for (componentIndex, (a, b)) in zip(sentComponents, readComponents).enumerated() {
                    let path: [LosslessJSON.PathComponent] = [.key("steps"), .index(stepIndex), .key("components"), .index(componentIndex)]
                    if path != componentPath && !a.isSemanticallyEqual(to: b) { changed += 1 }
                }
            }
            if changed > 0 {
                problems.append("\(changed) other component\(changed == 1 ? "" : "s") came back different from what was sent.")
            }
        }
        return WriteResult(detail: readBack, readBackComponent: readComponent, problems: problems, created: created)
    }
}

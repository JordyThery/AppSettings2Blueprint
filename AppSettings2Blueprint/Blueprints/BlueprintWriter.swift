import Foundation
import JTKit

/// A write that has been checked and backed up, waiting for review.
nonisolated struct PreparedWrite: Sendable {
    /// The Blueprint as fetched right before the backup.
    let latest: JamfPlatform.BlueprintDetail
    let edit: AppSettingsEdit
    let backupURL: URL
    /// The exact PATCH body: `{"steps": [...]}`.
    let patchBody: Data
    /// The component before and after, as a line diff of pretty-printed JSON.
    let diff: [DiffLine]

    var blueprintID: String { latest.id }
    var name: String { latest.overview.name }
    var changedLineCount: Int { diff.count { $0.kind != .unchanged } }
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

/// Writes a rule set into a Blueprint: re-GET and compare, back up, build the new
/// steps, review, PATCH `{"steps": [...]}` only, GET again and verify. Or creates
/// a new Blueprint with POST. Never sends divisionId; never deletes or undeploys.
nonisolated struct BlueprintWriter: Sendable {
    /// What a write request does, for the messages after it was sent.
    enum Action: Sendable {
        case steps, create, scope, restore
    }

    enum WriteError: Error, LocalizedError {
        case changedOnServer(name: String, loaded: String?, now: String?)
        case readOnly(name: String)
        case noScope(name: String)
        case emptyScope
        case notAnArray
        /// The write request succeeded, but reading the Blueprint back failed.
        case notVerified(name: String, id: String, action: Action, reason: String)
        /// The write request was sent but got no clear answer: Jamf may or may
        /// not have applied it.
        case outcomeUnknown(name: String, action: Action, reason: String)

        /// True when the write may have reached Jamf: the sheet must never offer
        /// to send it again as if nothing happened.
        var mayHaveWritten: Bool {
            switch self {
            case .notVerified, .outcomeUnknown: true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case let .changedOnServer(name, loaded, now):
                "“\(name)” was changed in Jamf after it was loaded (loaded: \(loaded ?? "unknown"), now: \(now ?? "unknown")). Reload the Blueprint and try again."
            case let .noScope(name):
                "“\(name)” has no device groups in scope. The Platform API rejects changes until it has one; set the scope with Edit Scope… first (for Jamf School, in Jamf School)."
            case let .readOnly(name):
                "“\(name)” is assigned to a division and can’t be changed through the API."
            case .emptyScope:
                "A Blueprint’s scope needs at least one device group."
            case .notAnArray:
                "The new steps aren’t an array, so nothing was sent: a partial PATCH would replace the Blueprint’s steps."
            case let .notVerified(name, id, action, reason):
                switch action {
                case .create:
                    "“\(name)” was created (ID \(id)), but reading it back failed: \(reason)\n\nDon’t create it again. Reload the Blueprints to check what Jamf holds."
                case .scope:
                    "The scope of “\(name)” was changed, but reading it back failed: \(reason)\n\nReload the Blueprint to check what Jamf holds."
                case .steps, .restore:
                    "“\(name)” was written, but reading it back failed: \(reason)\n\nReload the Blueprint to check what Jamf holds before writing again."
                }
            case let .outcomeUnknown(name, action, reason):
                switch action {
                case .create:
                    "Jamf didn’t answer clearly, so “\(name)” may or may not have been created: \(reason)\n\nReload the Blueprints and look for it before creating it again."
                case .scope:
                    "Jamf didn’t answer clearly, so the scope of “\(name)” may or may not have changed: \(reason)\n\nReload the Blueprint to check what Jamf holds."
                case .steps, .restore:
                    "Jamf didn’t answer clearly, so “\(name)” may or may not have been written: \(reason)\n\nReload the Blueprint to check what Jamf holds before writing again."
                }
            }
        }
    }

    let service: JamfPlatform.Blueprints
    /// Writes the full blueprint JSON before a PATCH; injectable for tests.
    var backup: @Sendable (JamfPlatform.BlueprintDetail) throws -> URL = { try BackupStore.write($0) }

    // MARK: Existing blueprint

    /// Before the review: concurrency check, backup, the new steps and their diff.
    func prepare(loaded: JamfPlatform.BlueprintDetail, declarations: [LosslessJSON], target: AppSettingsTarget) async throws -> PreparedWrite {
        let latest = try await service.detail(id: loaded.id)
        try checkUnchanged(loaded: loaded, latest: latest)
        if latest.isDivisionLocked { throw WriteError.readOnly(name: latest.overview.name) }
        if latest.scopeDeviceGroups.isEmpty { throw WriteError.noScope(name: latest.overview.name) }
        let backupURL = try backup(latest)
        let edit = try AppSettingsLocator.edit(blueprint: latest.json, declarations: declarations, target: target)
        let body = LosslessJSON.object(LosslessJSON.Object(["steps": edit.steps])).serialized()
        // Computed once here, off the main actor: a large allow list is
        // thousands of lines, too slow to diff on every redraw of the review.
        let diff = TextDiff.lines(
            from: edit.oldComponent?.serializedString(pretty: true) ?? "",
            to: edit.newComponent.serializedString(pretty: true)
        )
        return PreparedWrite(latest: latest, edit: edit, backupURL: backupURL, patchBody: body, diff: diff)
    }

    /// After the review: a last concurrency check, PATCH, GET and verify.
    func commit(_ prepared: PreparedWrite) async throws -> WriteResult {
        // The review can take a while; make sure nothing changed in the meantime.
        let current = try await service.detail(id: prepared.blueprintID)
        try checkUnchanged(loaded: prepared.latest, latest: current)
        try await send(name: prepared.name, action: .steps) {
            try await service.patchSteps(id: prepared.blueprintID, steps: prepared.edit.steps)
        }
        let readBack = try await readBack(id: prepared.blueprintID, name: prepared.name, action: .steps)
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
        try await send(name: latest.overview.name, action: .restore) {
            try await service.patchSteps(id: loaded.id, steps: steps)
        }
        let readBack = try await readBack(id: loaded.id, name: latest.overview.name, action: .restore)
        let same = (readBack.steps ?? .null).isSemanticallyEqual(to: steps)
        return WriteResult(
            detail: readBack, readBackComponent: nil,
            problems: same ? [] : ["The steps Jamf returned differ from the backup’s steps."],
            created: false
        )
    }

    // MARK: Scope

    /// Changes a Blueprint's device groups: concurrency check, backup, PATCH
    /// `{"scope": …}` only, GET and verify that the scope matches and the steps
    /// are untouched. Unlike a steps write, this works on an unscoped Blueprint.
    func changeScope(loaded: JamfPlatform.BlueprintDetail, deviceGroups: [String]) async throws -> ScopeChangeResult {
        guard !deviceGroups.isEmpty else { throw WriteError.emptyScope }
        let latest = try await service.detail(id: loaded.id)
        try checkUnchanged(loaded: loaded, latest: latest)
        if latest.isDivisionLocked { throw WriteError.readOnly(name: latest.overview.name) }
        let backupURL = try backup(latest)
        try await send(name: latest.overview.name, action: .scope) {
            try await service.patchScope(id: loaded.id, deviceGroups: deviceGroups)
        }
        let readBack = try await readBack(id: loaded.id, name: latest.overview.name, action: .scope)
        var problems: [String] = []
        if Set(readBack.scopeDeviceGroups) != Set(deviceGroups) {
            problems.append("The scope Jamf returned (\(readBack.scopeDeviceGroups.joined(separator: ", "))) differs from what was sent (\(deviceGroups.joined(separator: ", "))).")
        }
        if !(readBack.steps ?? .null).isSemanticallyEqual(to: latest.steps ?? .null) {
            problems.append("The Blueprint’s steps changed, although only the scope was sent. Compare them with the backup.")
        }
        return ScopeChangeResult(
            detail: readBack, previousGroups: latest.scopeDeviceGroups, backupURL: backupURL, problems: problems
        )
    }

    // MARK: New Blueprint

    /// POST a new Blueprint with one step holding the component, then GET and verify.
    func create(
        name: String,
        description: String?,
        deviceGroups: [String],
        stepName: String,
        activationPredicate: String?,
        declarations: [LosslessJSON]
    ) async throws -> WriteResult {
        guard !deviceGroups.isEmpty else { throw WriteError.emptyScope }
        let component = AppSettingsLocator.component(declarations: declarations)
        let step = AppSettingsLocator.step(name: stepName, components: [component], activationPredicate: activationPredicate)
        let id = try await send(name: name, action: .create) {
            try await service.create(name: name, description: description, deviceGroups: deviceGroups, steps: [step])
        }
        let readBack = try await readBack(id: id, name: name, action: .create)
        return verify(
            readBack: readBack, sentSteps: .array([step]),
            componentPath: [.key("steps"), .index(0), .key("components"), .index(0)], created: true
        )
    }

    // MARK: Sending

    /// Sends one write request. A clear refusal from Jamf (4xx) means nothing
    /// was written and is passed on; no answer, a 5xx or an unreadable answer
    /// leaves it open whether Jamf applied it (`outcomeUnknown`).
    @discardableResult
    private func send<T: Sendable>(name: String, action: Action, _ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch let error as JamfPlatform.APIError where error.hasCode(.divisionPatchNotAllowed) {
            throw WriteError.readOnly(name: name)
        } catch let error as JamfPlatform.APIError where Self.wasNotWritten(error) {
            throw error
        } catch {
            throw WriteError.outcomeUnknown(name: name, action: action, reason: error.localizedDescription)
        }
    }

    /// The GET after a successful write. Its failure doesn't undo the write.
    private func readBack(id: String, name: String, action: Action) async throws -> JamfPlatform.BlueprintDetail {
        do {
            return try await service.detail(id: id)
        } catch {
            throw WriteError.notVerified(name: name, id: id, action: action, reason: error.localizedDescription)
        }
    }

    /// Errors after which the request certainly changed nothing: refused before
    /// sending, or refused by Jamf with a 4xx answer.
    static func wasNotWritten(_ error: JamfPlatform.APIError) -> Bool {
        switch error.kind {
        case .refused, .invalidEnvironmentID, .invalidIdentifier, .signIn: true
        case let .status(status, _, _, _, _): (400..<500).contains(status)
        default: false
        }
    }

    // MARK: Checks

    /// The `updated` timestamp and the steps must both be as loaded.
    func checkUnchanged(loaded: JamfPlatform.BlueprintDetail, latest: JamfPlatform.BlueprintDetail) throws {
        guard Self.isUnchanged(loaded: loaded, latest: latest) else {
            throw WriteError.changedOnServer(name: latest.overview.name, loaded: loaded.overview.updated, now: latest.overview.updated)
        }
    }

    /// JTKit's `updated` comparison plus the steps themselves.
    static func isUnchanged(loaded: JamfPlatform.BlueprintDetail, latest: JamfPlatform.BlueprintDetail) -> Bool {
        loaded.isUnchanged(in: latest) && (loaded.steps ?? .null) == (latest.steps ?? .null)
    }

    /// Compares the read-back with what was sent: the written component must match,
    /// and every other component must be unchanged. Key order and number
    /// formatting are allowed to differ (the server may canonicalize them).
    func verify(readBack: JamfPlatform.BlueprintDetail, sentSteps: LosslessJSON, componentPath: [LosslessJSON.PathComponent], created: Bool) -> WriteResult {
        var problems: [String] = []
        let relative = Array(componentPath.dropFirst())  // drop .key("steps")
        let sentComponent = sentSteps.value(at: relative)
        let readComponent = readBack.json.value(at: componentPath)
        if let sentComponent, let readComponent {
            if !readComponent.isSemanticallyEqual(to: sentComponent) {
                problems.append("The App Settings component Jamf returned differs from what was sent. Compare them below before deploying.")
            }
        } else {
            problems.append("The written component wasn’t found at \(componentPath.pathString) in the read-back.")
        }

        let sent = sentSteps.arrayValue ?? []
        let read = readBack.steps?.arrayValue ?? []
        if sent.count != read.count {
            problems.append("The Blueprint has \(read.count) steps after the write; \(sent.count) were sent.")
        } else {
            var changed = 0
            for (stepIndex, (sentStep, readStep)) in zip(sent, read).enumerated() {
                // A step's own fields (name, activationPredicate, …) must come
                // back as sent; a dropped predicate would change who gets the rules.
                for member in sentStep.objectValue?.members ?? [] where member.key != "components" {
                    let returned = readStep[member.key]
                    if returned == nil || returned?.isSemanticallyEqual(to: member.value) == false {
                        problems.append("Step \(stepIndex + 1)’s \(member.key) came back different from what was sent.")
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

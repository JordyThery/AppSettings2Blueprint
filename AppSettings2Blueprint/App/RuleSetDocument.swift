import Foundation
import Observation

/// A blueprint the rule set belongs to.
nonisolated struct LinkedBlueprint: Hashable, Sendable {
    let id: String
    let name: String
}

/// The rule set being edited: undo/redo, unsaved-changes tracking, local files
/// and additions from the lookups.
@Observable
final class RuleSetDocument {
    /// The `.appsettings.json` file layout.
    nonisolated struct File: Codable, Sendable {
        static let formatIdentifier = "be.jordythery.appsettings2blueprint.ruleset"
        var format = File.formatIdentifier
        var version = 1
        var ruleSet: RuleSet
    }

    nonisolated struct DocumentError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let fileExtension = "appsettings.json"

    private(set) var ruleSet = RuleSet()
    /// The state last saved to (or opened from) a file, or written to Jamf.
    private(set) var savedRuleSet = RuleSet()
    private(set) var fileURL: URL?
    /// The blueprint this rule set was loaded from or last written to.
    var linkedBlueprint: LinkedBlueprint?
    /// Points the decoder raised when a rule set was loaded.
    var loadNotes: [String] = []
    /// A short confirmation, e.g. "Added 3 apps".
    var statusMessage: String?

    /// The window's undo manager, attached by the rule builder view.
    @ObservationIgnored weak var undoManager: UndoManager?

    var isDirty: Bool { ruleSet != savedRuleSet }
    var issues: [ValidationIssue] { RuleValidator.validate(ruleSet) }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    /// The component JSON exactly as it would be written to the Blueprint.
    var componentJSON: JSONValue { DeclarationEncoder.component(for: ruleSet) }

    // MARK: Editing

    /// Applies `change` as one undoable step.
    func update(_ actionName: String, _ change: (inout RuleSet) -> Void) {
        var next = ruleSet
        change(&next)
        guard next != ruleSet else { return }
        setRuleSet(next, actionName: actionName)
    }

    private func setRuleSet(_ newValue: RuleSet, actionName: String) {
        let previous = ruleSet
        ruleSet = newValue
        undoManager?.registerUndo(withTarget: self) { document in
            document.setRuleSet(previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Replaces the whole document without an undo step (new, open, load from Jamf).
    func replace(with ruleSet: RuleSet, fileURL: URL?, notes: [String] = [], linkedBlueprint: LinkedBlueprint? = nil) {
        self.ruleSet = ruleSet
        savedRuleSet = ruleSet
        self.fileURL = fileURL
        self.linkedBlueprint = linkedBlueprint
        loadNotes = notes
        statusMessage = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    func newRuleSet(platform: RulePlatform) {
        replace(with: RuleSet(platform: platform), fileURL: nil)
    }

    /// Marks the current state as saved, e.g. after writing it to Jamf.
    func markSaved() {
        savedRuleSet = ruleSet
    }

    // MARK: Jamf

    /// Loads the App Settings declarations of one com.jamf.ddm-strict component.
    func load(from detail: BlueprintDetail, location: AppSettingsLocation) {
        let declarations = detail.json.value(at: location.componentPath + [.key("configuration"), .key("declarations")])?
            .arrayValue ?? []
        var decoded = DeclarationDecoder.decode(declarations: declarations, name: detail.overview.name)
        let others = detail.appSettingsLocations.filter {
            $0.stepIndex != location.stepIndex || $0.componentIndex != location.componentIndex
        }
        if !others.isEmpty {
            decoded.notes.append("This blueprint has \(others.count) more App Settings declaration\(others.count == 1 ? "" : "s") in other components. Only step \(location.stepIndex + 1), component \(location.componentIndex + 1) was loaded, and only it is replaced when you write.")
        }
        replace(
            with: decoded.ruleSet, fileURL: nil, notes: decoded.notes,
            linkedBlueprint: LinkedBlueprint(id: detail.id, name: detail.overview.name)
        )
    }

    // MARK: Files

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(ruleSet: ruleSet))
        try data.write(to: url, options: .atomic)
        fileURL = url
        savedRuleSet = ruleSet
    }

    func open(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw DocumentError(message: "\(url.lastPathComponent) is not an AppSettings2Blueprint rule set: \(error.localizedDescription)")
        }
        guard file.format == File.formatIdentifier else {
            throw DocumentError(message: "\(url.lastPathComponent) has an unknown format (\(file.format)).")
        }
        guard file.version <= 1 else {
            throw DocumentError(message: "\(url.lastPathComponent) was written by a newer version of AppSettings2Blueprint.")
        }
        replace(with: file.ruleSet, fileURL: url)
    }

    // MARK: Adding from lookups

    /// Adds bundle IDs to the iOS app list, skipping duplicates. An empty macOS rule
    /// set switches to iOS first; a non-empty one is left alone.
    @discardableResult
    func addApps(_ apps: [(bundleID: String, name: String?)]) -> Bool {
        guard ensurePlatform(.iOS) else { return false }
        var added = 0
        update("Add Apps") { added = $0.addApps(apps) }
        let skipped = apps.count - added
        statusMessage = "Added \(added) app\(added == 1 ? "" : "s") to \(ruleSet.appListMode.key)"
            + (skipped > 0 ? " (\(skipped) already listed or empty)" : "") + "."
        return true
    }

    /// Adds binary rules to AllowedBinaries or DeniedBinaries, skipping exact duplicates.
    @discardableResult
    func addBinaryRules(_ rules: [BinaryRule], toAllowList: Bool) -> Bool {
        guard ensurePlatform(.macOS) else { return false }
        var added = 0
        update(toAllowList ? "Add Allowed Binaries" : "Add Denied Binaries") { ruleSet in
            var list = toAllowList ? ruleSet.allowedBinaries : ruleSet.deniedBinaries
            var known = Set(list.map(\.matchKey))
            for rule in rules where known.insert(rule.matchKey).inserted {
                list.append(rule)
                added += 1
            }
            if toAllowList { ruleSet.allowedBinaries = list } else { ruleSet.deniedBinaries = list }
        }
        let skipped = rules.count - added
        statusMessage = "Added \(added) rule\(added == 1 ? "" : "s") to \(toAllowList ? "AllowedBinaries" : "DeniedBinaries")"
            + (skipped > 0 ? " (\(skipped) already listed)" : "") + "."
        return true
    }

    /// Adds a permission-defaults entry for `identifier`, or reports that one exists.
    @discardableResult
    func addPermissionDefault(identifier: String, name: String?, platform: RulePlatform) -> Bool {
        guard ensurePlatform(platform) else { return false }
        if ruleSet.permissionDefaults.contains(where: { $0.appIdentifier == identifier }) {
            statusMessage = "\(name ?? identifier) already has permission defaults."
            return true
        }
        update("Add Permission Defaults") {
            $0.permissionDefaults.append(PermissionDefault(appIdentifier: identifier, displayName: name))
        }
        statusMessage = "Added permission defaults for \(name ?? identifier). Add an OrganizationJustification under Privacy."
        return true
    }

    /// Whether the rule set can take `platform` content: true when it already
    /// targets it, or when it is empty (it is switched). Never discards content.
    func ensurePlatform(_ platform: RulePlatform) -> Bool {
        if ruleSet.platform == platform { return true }
        if ruleSet.isEmpty {
            update("Change Platform") { $0.platform = platform }
            return true
        }
        statusMessage = "The rule set targets \(ruleSet.platform.displayName). Start a new \(platform.displayName) rule set to add these."
        return false
    }

    // MARK: CSV import

    /// Adds the rows of an App Settings Utility CSV. BundleID-Lookup rows go to the
    /// iOS app list; Local-Mac-Apps rows become binary rules with `strategy`.
    func importCSV(_ document: CSVDocument, strategy: BinaryMatchStrategy, toAllowList: Bool) -> Bool {
        switch document {
        case .bundleIDLookup(let rows):
            return addApps(rows.compactMap { row in row.bundleID.map { ($0, row.name) } })
        case .localMacApps(let rows):
            var rules: [BinaryRule] = []
            // Group slices by app so TeamID / SigningID strategies give one rule per app.
            let apps = Dictionary(grouping: rows, by: { $0.appPath ?? $0.name ?? "" })
            for path in rows.compactMap({ $0.appPath ?? $0.name }).uniqued() {
                guard let appRows = apps[path] else { continue }
                let binary = InspectedBinary(
                    name: appRows[0].name ?? path, path: path, isBundle: path.hasSuffix(".app"),
                    executablePath: nil, bundleID: appRows[0].bundleID, version: nil,
                    verification: .valid, slices: appRows.map(\.slice)
                )
                rules += strategy.rules(for: binary, slices: strategy == .exactBuild ? binary.slices : binary.defaultSlices)
            }
            return addBinaryRules(rules, toAllowList: toAllowList)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

import SwiftUI

/// Picks how an inspected app is matched, shows exactly which fields will be
/// written, and adds the rule(s) only when they pass the schema's minimum-field rules.
struct AddBinaryRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let binary: InspectedBinary

    @State private var toAllowList: Bool
    @State private var strategy: BinaryMatchStrategy
    @State private var selectedSlices: Set<String>
    // Custom fields, prefilled from the preferred slice.
    @State private var useCDHash = false
    @State private var useTeamID = true
    @State private var useSigningID = true
    @State private var usePathPrefix = false
    @State private var signingState = ""

    init(binary: InspectedBinary, toAllowList: Bool) {
        self.binary = binary
        _toAllowList = State(initialValue: toAllowList)
        // TeamID + SigningID is the recommended default; fall back when the signature lacks it.
        let preferred: BinaryMatchStrategy = BinaryMatchStrategy.appFromDeveloper.isAvailable(for: binary)
            ? .appFromDeveloper
            : (BinaryMatchStrategy.exactBuild.isAvailable(for: binary) ? .exactBuild : .custom)
        _strategy = State(initialValue: preferred)
        _selectedSlices = State(initialValue: Set(binary.slices.map(\.architecture)))
    }

    private var preferredSlice: SliceSignature? { binary.defaultSlices.first }

    private var rules: [BinaryRule] {
        if strategy == .custom {
            guard let slice = preferredSlice else { return [] }
            return [BinaryRule(
                cdHash: useCDHash ? slice.cdHash ?? "" : "",
                teamID: useTeamID ? slice.teamID ?? "" : "",
                signingID: useSigningID ? slice.signingID ?? "" : "",
                pathPrefix: usePathPrefix ? binary.suggestedPathPrefix : "",
                signingState: signingState,
                sourceDescription: [binary.name, useCDHash ? slice.architecture : nil].compactMap { $0 }.joined(separator: " · ")
            )]
        }
        let slices = strategy == .exactBuild
            ? binary.slices.filter { selectedSlices.contains($0.architecture) }
            : binary.defaultSlices
        return strategy.rules(for: binary, slices: slices)
    }

    private var issues: [ValidationIssue] {
        rules.flatMap { RuleValidator.binaryRuleIssues($0, inAllowList: toAllowList) }
    }

    private var canAdd: Bool { !rules.isEmpty && !issues.contains { $0.severity == .error } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(binary.name) to a Binary Rule")
                .font(.headline)
            Picker("List", selection: $toAllowList) {
                Text("AllowedBinaries").tag(true)
                Text("DeniedBinaries").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(BinaryMatchStrategy.allCases) { option in
                    let available = option.isAvailable(for: binary)
                    Button {
                        strategy = option
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: strategy == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(strategy == option ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(option.title) — \(option.fields)\(option == .appFromDeveloper ? " (recommended)" : "")")
                                    .font(.callout.weight(.medium))
                                Text(available ? option.tradeOff : "Unavailable: the signature has no \(option.fields).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .opacity(available ? 1 : 0.5)
                }
            }

            if strategy == .exactBuild && binary.slices.count > 1 {
                GroupBox("Slices (one rule each)") {
                    VStack(alignment: .leading) {
                        ForEach(binary.slices) { slice in
                            Toggle(isOn: Binding(
                                get: { selectedSlices.contains(slice.architecture) },
                                set: { if $0 { selectedSlices.insert(slice.architecture) } else { selectedSlices.remove(slice.architecture) } }
                            )) {
                                Text("\(slice.architecture)  \(slice.cdHash ?? "no CDHash")").font(.callout.monospaced())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if strategy == .custom, let slice = preferredSlice {
                GroupBox("Fields from \(slice.architecture)") {
                    VStack(alignment: .leading, spacing: 4) {
                        customToggle("CDHash", slice.cdHash, $useCDHash)
                        customToggle("TeamID", slice.teamID, $useTeamID)
                        customToggle("SigningID", slice.signingID, $useSigningID)
                        customToggle("PathPrefix", binary.suggestedPathPrefix, $usePathPrefix)
                        Picker("SigningState", selection: $signingState) {
                            Text("Not set (default All)").tag("")
                            ForEach(SigningStateValue.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .fixedSize()
                        if let detected = slice.signingState.declarationValue {
                            Text("Detected signing state: \(detected)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Will be written") {
                VStack(alignment: .leading, spacing: 4) {
                    if rules.isEmpty {
                        Text("Nothing: choose at least one slice or field.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        Text(DeclarationEncoder.binaryIdentifier(rule).serializedString())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    ForEach(issues) { IssueLabel(issue: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(rules.count) Rule\(rules.count == 1 ? "" : "s")") {
                    model.ruleSet.addBinaryRules(rules, toAllowList: toAllowList)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func customToggle(_ label: String, _ value: String?, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(label).frame(width: 90, alignment: .leading)
                Text(value ?? "Unavailable")
                    .font(.callout.monospaced())
                    .foregroundStyle(value == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .disabled(value == nil)
    }
}

/// Confirms what a CSV import will add before changing the rule set.
struct CSVImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: CSVDocument

    @State private var strategy: BinaryMatchStrategy = .appFromDeveloper
    @State private var toAllowList = false
    @State private var appListMode: AppListMode = .deny

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(document.format.title)")
                .font(.headline)
            Text("\(document.rowCount) row\(document.rowCount == 1 ? "" : "s").")
                .foregroundStyle(.secondary)
            switch document {
            case .bundleIDLookup:
                Picker("Add to", selection: $appListMode) {
                    ForEach(AppListMode.allCases) { Text($0.key).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text("Bundle IDs go to the iOS / iPadOS app list; duplicates are skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .localMacApps:
                Picker("Add to", selection: $toAllowList) {
                    Text("AllowedBinaries").tag(true)
                    Text("DeniedBinaries").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Match", selection: $strategy) {
                    ForEach(BinaryMatchStrategy.allCases.filter { $0 != .custom }) {
                        Text("\($0.title) — \($0.fields)").tag($0)
                    }
                }
                .fixedSize()
                Text(strategy.tradeOff + (strategy == .exactBuild ? " One rule is added per CSV row (per slice)." : " One rule is added per app."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Rows without the needed values are skipped. SigningState Unknown is never written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    if case .bundleIDLookup = document, model.ruleSet.ruleSet.platform == .iOS || model.ruleSet.ruleSet.isEmpty {
                        model.ruleSet.update("Change App List Mode") { $0.appListMode = appListMode }
                    }
                    _ = model.ruleSet.importCSV(document, strategy: strategy, toAllowList: toAllowList)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

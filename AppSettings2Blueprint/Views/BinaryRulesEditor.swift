import SwiftUI

/// Tab "macOS: Binaries": AllowedBinaries, DeniedBinaries and AlwaysAllowManagedApps.
struct BinaryRulesEditor: View {
    let document: RuleSetDocument

    var body: some View {
        let ruleSet = document.ruleSet
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if ruleSet.platform == .iOS {
                    Banner(style: .error, text: "Binary rules and AlwaysAllowManagedApps are macOS only. These entries are never written; remove them, or switch the rule set to macOS.")
                }
                if ruleSet.isMissingAllowListBaseline {
                    Banner(style: .warning, text: "AllowedBinaries is an allow list: anything not listed is blocked. Without AlwaysAllowManagedApps and an Apple-signed baseline, Apple apps and managed apps can be blocked too. Deploying asks for an extra confirmation while this is missing.") {
                        Button("Add Recommended Baseline") {
                            document.update("Add Recommended Baseline") { $0.addRecommendedBaseline() }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("baselineWarning")
                }

                Picker("AlwaysAllowManagedApps", selection: document.binding(\.alwaysAllowManagedApps, "Change AlwaysAllowManagedApps")) {
                    Text("Not set (default false)").tag(Bool?.none)
                    Text("true").tag(Bool?.some(true))
                    Text("false").tag(Bool?.some(false))
                }
                .fixedSize()
                .help("When AllowedBinaries is present, also allow apps installed by MDM.")

                RuleList(document: document, title: "AllowedBinaries", isAllowList: true, rules: ruleSet.allowedBinaries)
                RuleList(document: document, title: "DeniedBinaries", isAllowList: false, rules: ruleSet.deniedBinaries)

                Text("Add rules from Lookup → Local Mac Apps to pick a match strategy and fill the fields from the app's signature. Each AllowedBinaries entry needs a CDHash or TeamID; each DeniedBinaries entry needs a CDHash, TeamID or SigningID. A binary matches only when every field in the entry matches. The device always runs system-critical processes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }
}

private struct RuleList: View {
    let document: RuleSetDocument
    let title: String
    let isAllowList: Bool
    let rules: [BinaryRule]

    var body: some View {
        let keyPath: WritableKeyPath<RuleSet, [BinaryRule]> = isAllowList ? \.allowedBinaries : \.deniedBinaries
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(rules.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Add Empty Rule", systemImage: "plus") {
                    document.update("Add Binary Rule") { $0[keyPath: keyPath].append(BinaryRule()) }
                }
            }
            if rules.isEmpty {
                Text(isAllowList ? "Not set: no allow list is applied." : "Not set.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            ForEach(rules) { rule in
                BinaryRuleRow(document: document, keyPath: keyPath, rule: rule)
            }
        }
    }
}

private struct BinaryRuleRow: View {
    let document: RuleSetDocument
    let keyPath: WritableKeyPath<RuleSet, [BinaryRule]>
    let rule: BinaryRule

    var body: some View {
        let binding = document.binding(keyPath, id: rule.id, fallback: rule, "Edit Binary Rule")
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if rule.isAppleBaseline {
                        Label("Recommended baseline: every Apple-signed binary", systemImage: "apple.logo")
                            .font(.callout.weight(.medium))
                    } else if let source = rule.sourceDescription {
                        Text(source).font(.callout.weight(.medium))
                    } else {
                        Text("Rule").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        document.remove(keyPath, id: rule.id, "Remove Binary Rule")
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove rule")
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    field("CDHash", binding.cdHash, prompt: "40 hex characters")
                    field("TeamID", binding.teamID, prompt: "e.g. UBF8T346G9 or *APPLE*")
                    field("SigningID", binding.signingID, prompt: "e.g. com.microsoft.Outlook")
                    field("PathPrefix", binding.pathPrefix, prompt: "e.g. /Applications/Example.app/")
                    GridRow {
                        Text("SigningState").foregroundStyle(.secondary)
                        Picker("SigningState", selection: binding.signingState) {
                            Text("Not set (default All)").tag("")
                            ForEach(SigningStateValue.allCases) { Text($0.rawValue).tag($0.rawValue) }
                            if !rule.signingState.isEmpty && SigningStateValue(rawValue: rule.signingState) == nil {
                                Text("\(rule.signingState) (invalid)").tag(rule.signingState)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("SigningState")
                    }
                }
                ForEach(document.issues(for: rule.id)) { IssueLabel(issue: $0) }
            }
            .padding(4)
        }
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel(label)
        }
    }
}

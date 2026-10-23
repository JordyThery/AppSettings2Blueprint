import SwiftUI

/// Tab "Privacy: Permission Defaults": one entry per app, keyed by bundle ID (iOS)
/// or composed identifier (macOS).
struct PermissionDefaultsView: View {
    let document: RuleSetDocument

    var body: some View {
        let ruleSet = document.ruleSet
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(ruleSet.platform == .macOS
                         ? "Keys are composed identifiers: “Bundle-ID {Designated-Requirement}”. Add an app from Lookup → Local Mac Apps to fill it in. On macOS these defaults are written to a USER-channel declaration."
                         : "Keys are bundle IDs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Entry", systemImage: "plus") {
                        document.update("Add Permission Defaults") { $0.permissionDefaults.append(PermissionDefault()) }
                    }
                }
                if ruleSet.permissionDefaults.isEmpty {
                    ContentUnavailableView(
                        "No Permission Defaults",
                        systemImage: "hand.raised",
                        description: Text("Permission defaults suggest privacy permissions for an app. The user sees one consent prompt; if they decline, nothing is set.")
                    )
                }
                ForEach(ruleSet.permissionDefaults) { entry in
                    PermissionDefaultRow(document: document, entry: entry, platform: ruleSet.platform)
                }
                Text("Not supported on tvOS, visionOS or watchOS. Accessibility is not supported on iOS; LocationAccuracy is not supported on macOS. On macOS, WhileUsing location is equivalent to Always.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

private struct PermissionDefaultRow: View {
    let document: RuleSetDocument
    let entry: PermissionDefault
    let platform: RulePlatform

    var body: some View {
        let binding = document.binding(\.permissionDefaults, id: entry.id, fallback: entry, "Edit Permission Defaults")
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.displayName ?? "App").font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        document.remove(\.permissionDefaults, id: entry.id, "Remove Permission Defaults")
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove entry")
                }
                TextField(platform == .macOS ? "Composed identifier" : "Bundle ID", text: binding.appIdentifier, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .lineLimit(1...4)
                TextField("OrganizationJustification (required, shown to the user)", text: binding.organizationJustification, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    let keys = PermissionKey.allCases.filter { $0.isSupported(on: platform) || entry.value($0) != nil }
                    ForEach(Array(stride(from: 0, to: keys.count, by: 2)), id: \.self) { index in
                        GridRow {
                            picker(keys[index], binding: binding)
                            if index + 1 < keys.count { picker(keys[index + 1], binding: binding) }
                        }
                    }
                }
                ForEach(document.issues(for: entry.id)) { IssueLabel(issue: $0) }
            }
            .padding(4)
        }
    }

    private func picker(_ key: PermissionKey, binding: Binding<PermissionDefault>) -> some View {
        let current = entry.value(key)
        return Picker(key.title, selection: Binding(
            get: { current ?? "" },
            set: { binding.wrappedValue.setValue($0.isEmpty ? nil : $0, for: key) }
        )) {
            Text("Not set").tag("")
            ForEach(key.allowedValues, id: \.self) { Text($0).tag($0) }
            if let current, !key.allowedValues.contains(current) {
                Text("\(current) (invalid)").tag(current)
            }
        }
        .fixedSize()
        .accessibilityLabel(key.title)
        .help(key.isSupported(on: platform) ? key.rawValue : "\(key.rawValue) is not supported on \(platform.displayName); choose Not set.")
    }
}

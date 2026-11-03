import SwiftUI

/// Tab "iOS / iPadOS: Apps": AllowedApps or DeniedApps, one list at a time.
struct AppListEditor: View {
    let document: RuleSetDocument
    @State private var newBundleID = ""

    var body: some View {
        let ruleSet = document.ruleSet
        let listKeyPath: WritableKeyPath<RuleSet, [AppRule]> = ruleSet.appListMode == .allow ? \.allowedApps : \.deniedApps
        let otherList = ruleSet.appListMode == .allow ? ruleSet.deniedApps : ruleSet.allowedApps
        VStack(alignment: .leading, spacing: 10) {
            if ruleSet.platform == .macOS {
                Banner(style: .error, text: "AllowedApps and DeniedApps aren’t supported on macOS. These entries are never written; remove them, or switch the rule set to iOS / iPadOS. On macOS, use binary rules instead.")
            }
            Picker("Mode", selection: document.binding(\.appListMode, "Change App List Mode")) {
                ForEach(AppListMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(ruleSet.appListMode == .allow
                 ? "Only the listed apps can be shown or launched. Everything else, including Apple apps not listed, is hidden."
                 : "The listed apps can’t be shown or launched. Everything else is unaffected.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !otherList.isEmpty {
                Banner(style: .warning, text: "\(ruleSet.appListMode == .allow ? "DeniedApps" : "AllowedApps") also has \(otherList.count) entr\(otherList.count == 1 ? "y" : "ies"). Both lists are kept and written; with an allow list, a deny list only matters for apps that are also allowed. Switch the mode above to review it.")
            }

            HStack {
                TextField("Bundle ID, e.g. com.apple.news", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("newBundleID")
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List {
                ForEach(ruleSet.currentAppList) { app in
                    AppRuleRow(document: document, listKeyPath: listKeyPath, app: app)
                }
                .onMove { source, destination in
                    document.update("Reorder Apps") { $0[keyPath: listKeyPath].move(fromOffsets: source, toOffset: destination) }
                }
            }
            .overlay {
                if ruleSet.currentAppList.isEmpty {
                    ContentUnavailableView(
                        "No Apps",
                        systemImage: "app.dashed",
                        description: Text("Type a bundle ID above, or add apps from Lookup › App Store or Apple Built-in Apps.")
                    )
                }
            }
            // The warnings in a banner while they apply, in readable text; the tip stays below.
            if let warning = deniedSystemAppsWarning {
                Banner(style: .warning, text: warning)
            }
            Text("Include com.apple.webapp to \(ruleSet.appListMode == .allow ? "allow" : "deny") all web clips.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    /// Shown while DeniedApps holds Apple's own apps.
    private var deniedSystemAppsWarning: String? {
        let ruleSet = document.ruleSet
        guard ruleSet.appListMode == .deny else { return nil }
        let ids = ruleSet.deniedApps.map(\.bundleID)
        guard ids.contains(where: { $0.hasPrefix("com.apple.") }) else { return nil }
        let appStore = ids.contains("com.apple.AppStore")
            ? " Denying the App Store can also stop users accepting user-based VPP terms." : ""
        return "Denying Apple’s own apps can disable other features that rely on them.\(appStore)"
    }

    private func add() {
        let bundleID = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        document.addApps([(bundleID, nil)])
        newBundleID = ""
    }
}

private struct AppRuleRow: View {
    let document: RuleSetDocument
    let listKeyPath: WritableKeyPath<RuleSet, [AppRule]>
    let app: AppRule

    var body: some View {
        let binding = document.binding(listKeyPath, id: app.id, fallback: app, "Edit Bundle ID")
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("Bundle ID", text: binding.bundleID)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                if let name = app.displayName {
                    Text(name).foregroundStyle(.secondary)
                }
                IconButton(title: "Remove \(app.bundleID.isEmpty ? "App" : app.bundleID)", systemImage: "minus.circle", help: "Remove") {
                    document.remove(listKeyPath, id: app.id, "Remove App")
                }
            }
            ForEach(document.issues(for: app.id)) { IssueLabel(issue: $0) }
        }
        .padding(.vertical, 2)
        // Reordering without dragging, for the keyboard and VoiceOver.
        .contextMenu {
            Button("Move Up") { move(by: -1) }.disabled(!canMove(by: -1))
            Button("Move Down") { move(by: 1) }.disabled(!canMove(by: 1))
        }
        .accessibilityAction(named: "Move Up") { move(by: -1) }
        .accessibilityAction(named: "Move Down") { move(by: 1) }
    }

    private var index: Int? {
        document.ruleSet[keyPath: listKeyPath].firstIndex { $0.id == app.id }
    }

    private func canMove(by offset: Int) -> Bool {
        guard let index else { return false }
        return document.ruleSet[keyPath: listKeyPath].indices.contains(index + offset)
    }

    private func move(by offset: Int) {
        guard canMove(by: offset), let index else { return }
        document.update("Reorder Apps") { $0[keyPath: listKeyPath].swapAt(index, index + offset) }
    }
}

/// A colored message strip used across the editor tabs.
/// A status label as JTKit and `Banner` draw them: the symbol carries the
/// color, the text stays primary. Orange or green text on a light background
/// is about 2:1, below the 4.5:1 text needs.
struct TintedIconLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(color)
        }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    static func tintedIcon(_ color: Color) -> TintedIconLabelStyle { TintedIconLabelStyle(color: color) }
}

struct Banner<Actions: View>: View {
    enum Style { case error, warning, info }
    let style: Style
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
                .accessibilityLabel(style == .error ? "Error" : style == .warning ? "Warning" : "Note")
            // The text takes the row's width and wraps; no Spacer competes with it,
            // so the banner never reports a word-per-line height.
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            actions
        }
        .padding(10)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private var icon: String {
        switch style {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch style {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

extension Banner where Actions == EmptyView {
    init(style: Style, text: String) {
        self.init(style: style, text: text) { EmptyView() }
    }
}

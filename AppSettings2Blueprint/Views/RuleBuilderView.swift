import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rule Set → App Settings: the three editor tabs, issues and the live JSON preview.
struct RuleBuilderView: View {
    enum EditorTab: Hashable { case apps, binaries, privacy }

    @Environment(AppModel.self) private var model
    @State private var tab: EditorTab = .apps
    @State private var showsPreview = true
    @State private var pendingAction: PendingAction?
    @State private var csvImport: IdentifiedCSV?
    @State private var errorMessage: String?
    @State private var isWritingToJamf = false

    enum PendingAction: Identifiable {
        case new(RulePlatform)
        case open
        case switchPlatform(RulePlatform)
        var id: String {
            switch self {
            case .new(let platform): "new-\(platform)"
            case .open: "open"
            case .switchPlatform(let platform): "switch-\(platform)"
            }
        }
    }

    var body: some View {
        let document = model.ruleSet
        VStack(spacing: 0) {
            header
            Divider()
            if !document.loadNotes.isEmpty {
                NotesBanner(notes: document.loadNotes) { document.loadNotes = [] }
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TabView(selection: $tab) {
                        ForEach(visibleTabs, id: \.self) { tab in
                            tabContent(tab)
                                .tabItem { Text(title(for: tab)) }
                                .tag(tab)
                        }
                    }
                    .padding(8)
                    IssuesBar(issues: document.issues)
                }
                if showsPreview {
                    Divider()
                    JSONPreviewView(document: document)
                        .frame(width: 400)
                }
            }
        }
        .onAppear(perform: selectVisibleTab)
        .onChange(of: document.ruleSet.platform) { selectVisibleTab() }
        .confirmationDialog(
            // Switching platform keeps the entries; the other actions discard them.
            {
                if case .switchPlatform = pendingAction { return "Switch platform?" }
                return "Discard unsaved changes?"
            }(),
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            presenting: pendingAction
        ) { action in
            switch action {
            case .new(let platform):
                Button("Discard and Start New", role: .destructive) { document.newRuleSet(platform: platform) }
            case .open:
                Button("Discard and Open…", role: .destructive) { openFile() }
            case .switchPlatform(let platform):
                Button("Switch to \(platform.displayName)") {
                    document.update("Change Platform") { $0.platform = platform }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .switchPlatform(let platform):
                Text("The current entries stay in the rule set, but keys \(platform.displayName) does not support are marked as errors and never written. Remove them before saving.")
            default:
                Text("The rule set has changes that are not saved to a file or written to Jamf.")
            }
        }
        .sheet(isPresented: $isWritingToJamf) {
            TargetPickerView(app: model)
        }
        .sheet(item: $csvImport) { item in
            CSVImportSheet(document: item.document)
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        let document = model.ruleSet
        return HStack(spacing: 10) {
            TextField("Rule set name", text: document.binding(\.name, "Rename Rule Set"))
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(maxWidth: 260)
            Picker("Platform", selection: Binding(
                get: { document.ruleSet.platform },
                set: { platform in
                    guard platform != document.ruleSet.platform else { return }
                    if document.ruleSet.isEmpty {
                        document.update("Change Platform") { $0.platform = platform }
                    } else {
                        pendingAction = .switchPlatform(platform)
                    }
                }
            )) {
                ForEach(RulePlatform.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("The device family this rule set targets. iOS-only and macOS-only keys never mix.")
            if document.ruleSet.platform == .iOS {
                Toggle("Shared iPad", isOn: Binding(
                    get: { document.ruleSet.isSharedIPad },
                    set: { value in document.update("Change Shared iPad") { $0.isSharedIPad = value } }
                ))
                .toggleStyle(.checkbox)
                .help("On Shared iPad, Apple only accepts App Settings on the user channel. When on, the declaration is written as USER instead of SYSTEM.")
            }
            if let url = document.fileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(url.path(percentEncoded: false))
            }
            if let linked = document.linkedBlueprint {
                Label(linked.name, systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Loaded from or last written to this blueprint")
            }
            if document.isDirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Menu("New", systemImage: "doc.badge.plus") {
                ForEach(RulePlatform.allCases) { platform in
                    Button("\(platform.displayName) Rule Set") {
                        if document.isDirty { pendingAction = .new(platform) } else { document.newRuleSet(platform: platform) }
                    }
                }
            }
            .fixedSize()
            Button("Open…", systemImage: "folder") {
                if document.isDirty { pendingAction = .open } else { openFile() }
            }
            Button("Save…", systemImage: "square.and.arrow.down", action: saveFile)
                .disabled(document.hasErrors)
                .help(document.hasErrors ? "Fix the errors below before saving" : "Save the rule set as an .appsettings.json file")
            Button("Import CSV…", systemImage: "tablecells", action: importCSV)
                .help("Import an App Settings Utility CSV (BundleID-Lookup or Local-Mac-Apps)")
            Button("Write to Jamf…", systemImage: "square.and.arrow.up.on.square") { isWritingToJamf = true }
                .disabled(document.hasErrors || !model.hasActiveConnection)
                .help(!model.hasActiveConnection
                      ? "Add a Jamf connection in Settings first"
                      : (document.hasErrors ? "Fix the errors below first" : "Write this rule set to a new or existing Blueprint"))
            Toggle(isOn: $showsPreview) {
                Label("JSON Preview", systemImage: "curlybraces")
            }
            .toggleStyle(.button)
            .help("Show the exact component JSON")
        }
        .labelStyle(.titleAndIcon)
        .padding(10)
    }

    // MARK: Tabs

    /// The platform's own tabs, plus a mismatched tab while it still holds entries,
    /// so they can be reviewed and removed.
    private var visibleTabs: [EditorTab] {
        let ruleSet = model.ruleSet.ruleSet
        switch ruleSet.platform {
        case .iOS:
            let hasMac = !ruleSet.allowedBinaries.isEmpty || !ruleSet.deniedBinaries.isEmpty || ruleSet.alwaysAllowManagedApps != nil
            return [.apps] + (hasMac ? [.binaries] : []) + [.privacy]
        case .macOS:
            let hasIOS = !ruleSet.allowedApps.isEmpty || !ruleSet.deniedApps.isEmpty
            return (hasIOS ? [.apps] : []) + [.binaries, .privacy]
        }
    }

    private func title(for tab: EditorTab) -> String {
        let issues = model.ruleSet.issues
        let area: ValidationIssue.Area = switch tab {
        case .apps: .apps
        case .binaries: .binaries
        case .privacy: .privacy
        }
        let errorCount = issues.filter { $0.area == area && $0.severity == .error }.count
        let base = switch tab {
        case .apps: "iOS / iPadOS: Apps"
        case .binaries: "macOS: Binaries"
        case .privacy: "Privacy: Permission Defaults"
        }
        return errorCount > 0 ? "\(base) (\(errorCount))" : base
    }

    @ViewBuilder
    private func tabContent(_ tab: EditorTab) -> some View {
        switch tab {
        case .apps: AppListEditor(document: model.ruleSet)
        case .binaries: BinaryRulesEditor(document: model.ruleSet)
        case .privacy: PermissionDefaultsView(document: model.ruleSet)
        }
    }

    private func selectVisibleTab() {
        if !visibleTabs.contains(tab) { tab = visibleTabs.first ?? .privacy }
    }

    // MARK: Files

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an .appsettings.json rule set."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.ruleSet.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveFile() {
        let document = model.ruleSet
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = document.ruleSet.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "\(base).\(RuleSetDocument.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.save(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a BundleID-Lookup or Local-Mac-Apps CSV from App Settings Utility or this app."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            csvImport = IdentifiedCSV(document: try CSVImporter.importDocument(String(contentsOf: url, encoding: .utf8)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IdentifiedCSV: Identifiable {
    let id = UUID()
    let document: CSVDocument
}

/// Decoder notes shown after loading a rule set.
private struct NotesBanner: View {
    let notes: [String]
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { Text($0) }
            }
            .font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(10)
        .background(.blue.opacity(0.08))
    }
}

/// Error and warning counts, expandable to the full list.
private struct IssuesBar: View {
    let issues: [ValidationIssue]
    @State private var isExpanded = false

    var body: some View {
        let errorCount = issues.filter { $0.severity == .error }.count
        let warningCount = issues.count - errorCount
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if issues.isEmpty {
                    Label("No issues. The rule set matches the App Settings schema.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    if errorCount > 0 {
                        Label("\(errorCount) error\(errorCount == 1 ? "" : "s") (saving is disabled)", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    if warningCount > 0 {
                        Label("\(warningCount) warning\(warningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(isExpanded ? "Hide" : "Show All") { isExpanded.toggle() }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("issuesSummary")
            if isExpanded && !issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues) { IssueLabel(issue: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 150)
                .padding(.bottom, 6)
            }
        }
    }
}

struct IssueLabel: View {
    let issue: ValidationIssue

    var body: some View {
        Label {
            Text(issue.message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

// MARK: - Bindings

extension RuleSetDocument {
    /// A binding to a rule set property; each change is one undo step.
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<RuleSet, Value>, _ actionName: String) -> Binding<Value> {
        Binding(
            get: { self.ruleSet[keyPath: keyPath] },
            set: { newValue in self.update(actionName) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A binding to one element of a list, found by ID. Reading a removed element
    /// returns its last known value, so a view being torn down never crashes.
    func binding<Item: Identifiable & Equatable>(
        _ keyPath: WritableKeyPath<RuleSet, [Item]>,
        id: Item.ID,
        fallback: Item,
        _ actionName: String
    ) -> Binding<Item> {
        Binding(
            get: { self.ruleSet[keyPath: keyPath].first { $0.id == id } ?? fallback },
            set: { newValue in
                self.update(actionName) { ruleSet in
                    if let index = ruleSet[keyPath: keyPath].firstIndex(where: { $0.id == id }) {
                        ruleSet[keyPath: keyPath][index] = newValue
                    }
                }
            }
        )
    }

    func remove<Item: Identifiable>(_ keyPath: WritableKeyPath<RuleSet, [Item]>, id: Item.ID, _ actionName: String) {
        update(actionName) { $0[keyPath: keyPath].removeAll { $0.id == id } }
    }

    func issues(for itemID: UUID) -> [ValidationIssue] {
        issues.filter { $0.itemID == itemID }
    }
}

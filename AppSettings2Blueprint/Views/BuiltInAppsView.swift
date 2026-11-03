import AppKit
import SwiftUI

/// Lookup › Apple Built-in Apps: the embedded reference list of Apple app bundle IDs.
struct BuiltInAppsView: View {
    enum ListChoice: String, CaseIterable, Identifiable {
        case builtIn = "Built-in Only"
        case all = "All Apple Apps"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var choice: ListChoice = .builtIn
    @State private var searchText = ""
    @State private var selection: Set<AppleBuiltInApps.App.ID> = []
    @State private var errorMessage: String?

    var body: some View {
        switch model.builtInApps {
        case .success(let list):
            content(list)
        case .failure(let error):
            ContentUnavailableView(
                "Apple App List Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
        }
    }

    private func content(_ list: AppleBuiltInApps) -> some View {
        let source = choice == .builtIn ? list.builtInApps : list.apps
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let apps = query.isEmpty ? source : source.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
        return VStack(spacing: 0) {
            HStack {
                Picker("List", selection: $choice) {
                    ForEach(ListChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Text(query.isEmpty ? "^[\(source.count) apps](inflect: true)" : "\(apps.count) of \(source.count) apps")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add to Rule Set", systemImage: "plus.circle") {
                    model.ruleSet.addApps(apps.filter { selection.contains($0.id) }.map { ($0.bundleId, $0.name) })
                }
                .disabled(selection.isEmpty)
                .help("Add the selected bundle IDs to the iOS / iPadOS app list; duplicates are skipped")
                CopyButton(title: "Copy Bundle IDs") {
                    apps.filter { selection.contains($0.id) }.map(\.bundleId).joined(separator: "\n")
                }
                .disabled(selection.isEmpty)
                Button("Export CSV…", systemImage: "tablecells") {
                    // `apps`, like the other buttons, so a search filter hides the same rows everywhere.
                    let rows = apps.filter { selection.contains($0.id) }.map(BundleIDLookupRow.init(appleApp:))
                    do { try CSVExport.save(.bundleIDLookup(rows)) } catch { errorMessage = error.localizedDescription }
                }
                .disabled(selection.isEmpty)
                .help("Save the selected apps as an App Settings Utility BundleID-Lookup CSV")
            }
            .padding(10)
            Divider()
            Table(apps, selection: $selection) {
                TableColumn("Name") { app in
                    HStack(spacing: 4) {
                        Text(app.name)
                        if app.name == "Playground" {
                            Text("Image Playground")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Bundle ID") { app in
                    Text(app.bundleId).font(.body.monospaced())
                }
                TableColumn("Built-in") { app in
                    if app.builtIn {
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                            .accessibilityLabel("Built-in")
                    }
                }
                .width(60)
            }
            .contextMenu(forSelectionType: AppleBuiltInApps.App.ID.self) { ids in
                Button(ids.count > 1 ? "Add \(ids.count) Apps to Rule Set" : "Add to Rule Set") {
                    model.ruleSet.addApps(apps.filter { ids.contains($0.id) }.map { ($0.bundleId, $0.name) })
                }
                Button(ids.count > 1 ? "Copy \(ids.count) Bundle IDs" : "Copy Bundle ID") {
                    copy(apps.filter { ids.contains($0.id) }.map(\.bundleId))
                }
            }
            .overlay {
                if apps.isEmpty { ContentUnavailableView.search }
            }
            Divider()
            SourceFooter(list: list)
                .padding(10)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Apple apps")
        .onChange(of: choice) { selection = [] }
        .alert("Couldn’t Export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func copy(_ bundleIDs: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleIDs.joined(separator: "\n"), forType: .string)
    }
}

/// Where the list comes from and what it does not promise.
private struct SourceFooter: View {
    let list: AppleBuiltInApps

    private var sourceLine: AttributedString {
        let markdown = "Source: Apple’s list of app bundle IDs, verified \(list.verifiedDisplay), as embedded in [App Settings Utility](https://github.com/cantscript/AppSettingsUtility) by Anthony Darlow (MIT)."
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString("Source: Apple’s list of app bundle IDs, verified \(list.verifiedDisplay), as embedded in App Settings Utility by Anthony Darlow (MIT).")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // One text with the link inside, so it wraps instead of being cut off.
            Text(sourceLine)
                .fixedSize(horizontal: false, vertical: true)
            if let appleURL = URL(string: list.appleSource) {
                Link(list.appleSource, destination: appleURL)
            }
            ForEach(list.notes, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

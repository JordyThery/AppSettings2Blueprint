import AppKit
import SwiftUI

/// Lookup → Apple Built-in Apps: the embedded reference list of Apple app bundle IDs.
struct BuiltInAppsView: View {
    enum ListChoice: String, CaseIterable, Identifiable {
        case builtIn = "Built-in only"
        case all = "All Apple apps"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var choice: ListChoice = .builtIn
    @State private var searchText = ""
    @State private var selection: Set<AppleBuiltInApps.App.ID> = []

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
                Text("\(source.count) apps")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Bundle IDs", systemImage: "doc.on.doc") {
                    copy(apps.filter { selection.contains($0.id) }.map(\.bundleId))
                }
                .disabled(selection.isEmpty)
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
                    }
                }
                .width(60)
            }
            .contextMenu(forSelectionType: AppleBuiltInApps.App.ID.self) { ids in
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
    }

    private func copy(_ bundleIDs: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleIDs.joined(separator: "\n"), forType: .string)
    }
}

/// Where the list comes from and what it does not promise.
private struct SourceFooter: View {
    let list: AppleBuiltInApps

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Source: Apple's list of app bundle IDs, verified \(list.verifiedDisplay), as embedded in")
                if let repository = URL(string: "https://github.com/cantscript/AppSettingsUtility") {
                    Link("App Settings Utility", destination: repository)
                }
                Text("by Anthony Darlow (MIT).")
            }
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

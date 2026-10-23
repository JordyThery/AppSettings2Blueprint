import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lookup → Local Mac Apps: scanned and dropped apps, and the inspector for the selected one.
struct LocalAppsView: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = app.localApps
        HStack(spacing: 0) {
            LocalAppListView()
                .frame(width: 300)
            Divider()
            Group {
                if let path = model.selectedPath {
                    InspectorView(path: path)
                        .id(path)
                } else {
                    ContentUnavailableView(
                        "No App Selected",
                        systemImage: "macwindow",
                        description: Text("Select an app, or drop an .app or executable anywhere on this window.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls.filter(\.isFileURL))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter apps")
        .alert(
            "Not an app or executable",
            isPresented: Binding(get: { !model.rejectedDrops.isEmpty }, set: { if !$0 { model.rejectedDrops = [] } })
        ) {
            Button("OK") { model.rejectedDrops = [] }
        } message: {
            Text("Only .app bundles and Mach-O executables can be inspected: \(model.rejectedDrops.joined(separator: ", "))")
        }
        .task {
            if !model.hasScanned { model.scan() }
        }
    }
}

private struct LocalAppListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.localApps
        VStack(spacing: 0) {
            HStack {
                Button("Scan", systemImage: "arrow.clockwise") { model.scan() }
                    .disabled(model.isScanning)
                    .help("Scan the application folders again")
                Button("Choose…", systemImage: "folder") { choose() }
                    .help("Pick an .app bundle or an executable to inspect")
                Spacer()
            }
            .padding(8)
            Toggle("Include ~/Applications", isOn: $model.includesUserApplications)
                .toggleStyle(.checkbox)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider()
            List(selection: $model.selectedPath) {
                if !model.visibleAdded.isEmpty {
                    Section("Added") {
                        ForEach(model.visibleAdded) { entry in
                            LocalAppRow(entry: entry)
                                .tag(entry.path)
                                .contextMenu {
                                    Button("Remove from List") { model.removeAdded(path: entry.path) }
                                }
                        }
                    }
                }
                Section("Scanned") {
                    ForEach(model.visibleScanned) { entry in
                        LocalAppRow(entry: entry)
                            .tag(entry.path)
                    }
                }
            }
            .overlay {
                if model.isScanning && model.scanned.isEmpty {
                    ProgressView("Scanning…")
                }
            }
            Divider()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .help(model.folders.joined(separator: "\n"))
        }
    }

    private var statusText: String {
        let model = app.localApps
        if model.isScanning { return "Scanning \(model.folders.count) folders…" }
        guard model.hasScanned else { return "Not scanned" }
        return "\(model.scanned.count) apps in \(model.folders.count) folders"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle, .unixExecutable, .executable, .data]
        panel.message = "Choose an .app bundle or a Mach-O executable. It is only read, never launched."
        panel.prompt = "Inspect"
        guard panel.runModal() == .OK else { return }
        app.localApps.add(urls: panel.urls)
    }
}

private struct LocalAppRow: View {
    let entry: LocalAppEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(entry.path)
    }
}

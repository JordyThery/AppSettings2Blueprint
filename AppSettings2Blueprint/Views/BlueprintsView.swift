import JTKit
import SwiftUI

/// Jamf › Blueprints: the Blueprint list and the raw JSON of the selected one.
struct BlueprintsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            BlueprintListView()
                .frame(width: 300)
            Divider()
            Group {
                if let id = model.selectedBlueprintID {
                    BlueprintDetailPane(blueprintID: id)
                } else {
                    ContentUnavailableView(
                        "No Blueprint Selected",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Select a Blueprint to see its raw JSON.")
                    )
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter Blueprints")
        .task {
            if model.listState == .idle && model.hasActiveConnection { model.refresh() }
        }
    }
}

private struct BlueprintListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(model.visibleOverviews, selection: $model.selectedBlueprintID) { overview in
                BlueprintRow(overview: overview, detail: model.details[overview.id])
                    .tag(overview.id)
            }
            .overlay { overlay }
            Divider()
            statusBar
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !model.hasActiveConnection {
            ContentUnavailableView {
                Label("No Connection", systemImage: "network.slash")
            } description: {
                Text("Add a Jamf Platform API connection in Settings, or try the app with sample data.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
                Button("Try Demo Mode") { model.demo.isOn = true }
            }
        } else if model.overviews.isEmpty, model.listState != .listing {
            ContentUnavailableView("No Blueprints", systemImage: "square.stack.3d.up.slash")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            switch model.listState {
            case .idle:
                Text("Not loaded")
            case .listing:
                ProgressView().controlSize(.small)
                Text("Listing Blueprints…")
            case .finished(let date):
                let total = model.overviews.count
                let visible = model.visibleOverviews.count
                if visible == total {
                    Text("^[\(total) Blueprint](inflect: true) · \(date.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("\(visible) of \(total) Blueprints · \(date.formatted(date: .omitted, time: .shortened))")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
                Text(message).lineLimit(2).help(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .announcesOnAppear(message)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
}

private struct BlueprintRow: View {
    let overview: JamfPlatform.BlueprintOverview
    let detail: JamfPlatform.BlueprintDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(overview.name).lineLimit(1)
                Spacer(minLength: 4)
                if let state = overview.deploymentState?.state {
                    DeploymentStateBadge(state: state)
                }
            }
            if let detail, detail.containsAppSettings {
                Label("App Settings", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Header, the App Settings declarations found in the Blueprint, and its raw JSON.
private struct BlueprintDetailPane: View {
    @Environment(AppModel.self) private var model
    let blueprintID: String
    @State private var isShowingBackups = false
    @State private var isDeploying = false
    @State private var isEditingScope = false

    var body: some View {
        if let detail = model.details[blueprintID] {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    BlueprintHeader(detail: detail)
                    Button("Reload", systemImage: "arrow.clockwise") { model.loadDetail(id: blueprintID) }
                        .disabled(model.loadingDetailIDs.contains(blueprintID))
                    Button("Backups…", systemImage: "clock.arrow.circlepath") { isShowingBackups = true }
                        .help("Backups written before each change; restore one")
                    if !model.isJamfSchool {
                        Button("Edit Scope…", systemImage: "person.3") { isEditingScope = true }
                            .help(model.isReadOnly(detail) ? "This Blueprint is assigned to a division and can’t be changed through the API" : "Choose the device groups this Blueprint is scoped to")
                            .disabled(model.isReadOnly(detail))
                    }
                    Button("Deploy…", systemImage: "paperplane") { isDeploying = true }
                        .help(detail.scopeDeviceGroups.isEmpty ? "The Blueprint has no device groups in scope" : "Deploy this Blueprint to its scope, after a confirmation")
                        .disabled(detail.scopeDeviceGroups.isEmpty)
                }
                .padding(10)
                AppSettingsSummary(detail: detail)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                Divider()
                RawJSONView(detail: detail)
            }
            .sheet(isPresented: $isShowingBackups) {
                RestoreBackupSheet(detail: detail)
            }
            .sheet(isPresented: $isDeploying) {
                DeployConfirmationSheet(app: model, detail: detail)
            }
            .sheet(isPresented: $isEditingScope) {
                EditScopeSheet(app: model, detail: detail)
            }
            // Blueprint menu commands, also when they opened this pane.
            .onChange(of: model.blueprintCommand, initial: true) {
                // Only a command chosen for this Blueprint.
                guard let command = model.takeBlueprintCommand(for: blueprintID) else { return }
                switch command {
                case .reload: model.loadDetail(id: blueprintID)
                case .backups: isShowingBackups = true
                case .editScope: if !model.isJamfSchool && !model.isReadOnly(detail) { isEditingScope = true }
                case .deploy: if !detail.scopeDeviceGroups.isEmpty { isDeploying = true }
                }
            }
        } else if let error = model.detailErrors[blueprintID] {
            ContentUnavailableView {
                Label("Couldn’t Load Blueprint", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { model.loadDetail(id: blueprintID) }
            }
        } else {
            ProgressView("Loading Blueprint…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Lists where App Settings declarations were found, with their component and
/// channel, and loads an editable one into the rule set.
private struct AppSettingsSummary: View {
    @Environment(AppModel.self) private var model
    let detail: JamfPlatform.BlueprintDetail
    @State private var pendingLoad: AppSettingsLocation?

    private var locations: [AppSettingsLocation] { detail.appSettingsLocations }

    var body: some View {
        content
            .confirmationDialog(
                "Replace the Current Rule Set?",
                isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } }),
                presenting: pendingLoad
            ) { location in
                Button("Discard and Load", role: .destructive) { load(location) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The rule set has unsaved changes.")
            }
    }

    private func load(_ location: AppSettingsLocation) {
        model.ruleSet.load(from: detail, location: location)
        model.ruleSet.statusMessage = "Loaded the App Settings of “\(detail.overview.name)” into the rule set."
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if locations.isEmpty {
                Label("No com.apple.configuration.app.settings declaration in this Blueprint.", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(locations) { location in
                    HStack(spacing: 6) {
                        Image(systemName: location.isStrictComponent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(location.isStrictComponent ? .green : .orange)
                        Text("App Settings at \(location.path.pathString)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        if location.isStrictComponent {
                            Button("Load into Editor") {
                                if model.ruleSet.isDirty { pendingLoad = location } else { load(location) }
                            }
                            .controlSize(.small)
                            .help("Edit this component’s App Settings in the editor")
                        } else {
                            Text("Not editable (\(location.componentIdentifier))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("component \(location.componentIdentifier.isEmpty ? "(no identifier)" : location.componentIdentifier) · channelType \(location.channelType ?? "(missing)") · kind \(location.kind ?? "(missing)")\(location.stepName.map { " · step “\($0)”" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

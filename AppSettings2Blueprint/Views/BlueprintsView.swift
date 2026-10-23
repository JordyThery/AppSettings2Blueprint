import SwiftUI

/// Jamf → Blueprints: the Blueprint list and the raw JSON of the selected one.
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
            if model.listState == .idle && model.profileStore.selectedProfile != nil { model.refresh() }
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
        if model.profileStore.selectedProfile == nil {
            ContentUnavailableView {
                Label("No Connection", systemImage: "network.slash")
            } description: {
                Text("Add a Jamf Platform API connection in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
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
                Text("\(model.overviews.count) Blueprints · \(date.formatted(date: .omitted, time: .shortened))")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2).help(message)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
}

private struct BlueprintRow: View {
    let overview: BlueprintOverview
    let detail: BlueprintDetail?

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

    var body: some View {
        if let detail = model.details[blueprintID] {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    BlueprintHeader(detail: detail)
                    Button("Reload", systemImage: "arrow.clockwise") { model.loadDetail(id: blueprintID) }
                        .disabled(model.loadingDetailIDs.contains(blueprintID))
                }
                .padding(10)
                AppSettingsSummary(locations: detail.appSettingsLocations)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                Divider()
                RawJSONView(detail: detail)
            }
        } else if let error = model.detailErrors[blueprintID] {
            ContentUnavailableView {
                Label("Couldn't Load Blueprint", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Retry") { model.loadDetail(id: blueprintID) }
            }
        } else {
            ProgressView("Loading Blueprint…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Lists where App Settings declarations were found, with their component and channel.
private struct AppSettingsSummary: View {
    let locations: [AppSettingsLocation]

    var body: some View {
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

import JTKit
import SwiftUI

/// Edit Scope: choose the device groups of an existing blueprint. Only the scope
/// is sent; the steps are left exactly as they are.
struct EditScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: EditScopeModel

    init(app: AppModel, detail: JamfPlatform.BlueprintDetail) {
        _model = State(initialValue: EditScopeModel(app: app, detail: detail))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .editing:
                EditScopeForm(model: model, cancel: { dismiss() })
            case .saving:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Checking the blueprint, writing a backup and changing the scope…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let result):
                ScopeResultView(model: model, result: result, done: { dismiss() })
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label("Scope Not Changed", systemImage: "xmark.octagon.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Close", role: .cancel) { dismiss() }
                        Button("Back") { model.phase = .editing }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 560)
        .task { if model.app.deviceGroups.isEmpty { model.app.loadDeviceGroups() } }
    }
}

private struct EditScopeForm: View {
    @Bindable var model: EditScopeModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Scope").font(.title3.weight(.semibold))
                Text("“\(model.detail.overview.name)”").foregroundStyle(.secondary)
            }
            TextField("Filter device groups", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
            List(model.rows) { row in
                Toggle(isOn: Binding(
                    get: { model.selected.contains(row.id) },
                    set: { if $0 { model.selected.insert(row.id) } else { model.selected.remove(row.id) } }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let count = row.memberCount {
                            Text("^[\(count) device](inflect: true)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .overlay {
                if model.app.isLoadingDeviceGroups && model.app.deviceGroups.isEmpty {
                    ProgressView()
                } else if let error = model.app.deviceGroupsError {
                    ContentUnavailableView {
                        Label("Couldn't Load Device Groups", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { model.app.loadDeviceGroups() }
                    }
                }
            }

            ChangeSummary(model: model)

            Divider()
            HStack {
                if let reason = model.blockingReason {
                    Label(reason, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Change Scope") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.blockingReason != nil)
            }
        }
        .padding(16)
    }
}

/// Added and removed groups, with the removal warning for deployed blueprints.
private struct ChangeSummary: View {
    @Bindable var model: EditScopeModel

    var body: some View {
        if model.hasChanges {
            VStack(alignment: .leading, spacing: 6) {
                if !model.addedGroups.isEmpty {
                    Label("Add: \(names(model.addedGroups))", systemImage: "plus.circle")
                        .foregroundStyle(.green)
                }
                if !model.removedGroups.isEmpty {
                    Label("Remove: \(names(model.removedGroups))", systemImage: "minus.circle")
                        .foregroundStyle(.orange)
                }
                if model.removalNeedsAcknowledgement {
                    Toggle("I understand that devices in the removed groups lose this blueprint's settings at the next deployment.", isOn: $model.acknowledgesRemoval)
                        .foregroundStyle(.orange)
                }
                Text("Only the scope is sent; the steps stay exactly as they are. Devices are affected at the next deployment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func names(_ ids: [String]) -> String {
        ids.map { id in
            let name = model.app.groupName(id)
            return model.memberCount(id).map { "\(name) (\($0))" } ?? name
        }
        .joined(separator: ", ")
    }
}

private struct ScopeResultView: View {
    let model: EditScopeModel
    let result: ScopeChangeResult
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.isVerified {
                Label("Scope changed and verified", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                Text("The server returned the new scope, and the steps are unchanged.")
                    .foregroundStyle(.secondary)
            } else {
                Label("Scope changed, but the read-back differs", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(result.problems, id: \.self) { Text($0) }
            }
            HStack(spacing: 8) {
                Text("“\(result.detail.overview.name)”").font(.headline)
                if let state = result.detail.overview.deploymentState?.state { DeploymentStateBadge(state: state) }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Before").foregroundStyle(.secondary)
                    Text(result.previousGroups.isEmpty ? "No device groups" : result.previousGroups.map(model.app.groupName).joined(separator: ", "))
                }
                GridRow {
                    Text("After").foregroundStyle(.secondary)
                    Text(result.detail.scopeDeviceGroups.map(model.app.groupName).joined(separator: ", "))
                }
                GridRow {
                    Text("Backup").foregroundStyle(.secondary)
                    Text(result.backupURL.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .font(.callout)
            Text("Devices are affected at the next deployment. Deploying is a separate, confirmed step.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

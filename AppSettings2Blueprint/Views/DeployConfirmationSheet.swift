import JTKit
import SwiftUI

/// The explicit confirmation before deploying, then the deployment's progress.
/// Nothing deploys until the box is checked and Deploy is pressed.
struct DeployConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DeployModel

    init(app: AppModel, detail: JamfPlatform.BlueprintDetail) {
        _model = State(initialValue: DeployModel(app: app, detail: detail))
    }

    var body: some View {
        DeployFlowView(model: model, close: {
            model.stopWatching()
            dismiss()
        })
        .frame(width: 560)
        .task { if model.app.deviceGroups.isEmpty && !model.app.isJamfSchool { model.app.loadDeviceGroups() } }
    }
}

/// The confirmation and status content, also shown inside the write sheet.
struct DeployFlowView: View {
    @Bindable var model: DeployModel
    let close: () -> Void

    var body: some View {
        switch model.phase {
        case .confirming:
            ConfirmView(model: model, close: close)
        case .deploying:
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting the deployment…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        case .watching(let status):
            StatusView(name: model.detail.overview.name, status: status, isFinal: false, close: close)
        case .finished(let status):
            StatusView(name: model.detail.overview.name, status: status, isFinal: true, close: close)
        case .failed(let message):
            DeployErrorView(
                title: "Deployment Not Started", icon: "xmark.octagon.fill", color: .red,
                message: message, close: close
            )
        case .uncertain(let message):
            DeployErrorView(
                title: "Deployment May Have Started", icon: "exclamationmark.triangle.fill", color: .orange,
                message: message, close: close
            )
        case .watchFailed(let message):
            DeployErrorView(
                title: "Deployment Started, Status Unknown", icon: "exclamationmark.triangle.fill", color: .orange,
                message: "The deployment was started, but checking its status failed. It continues in Jamf; check the Blueprint later.\n\n\(message)",
                close: close
            )
        }
    }
}

private struct DeployErrorView: View {
    let title: String
    let icon: String
    let color: Color
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct ConfirmView: View {
    @Bindable var model: DeployModel
    let close: () -> Void

    var body: some View {
        let detail = model.detail
        let warnings = model.allowListWarnings
        VStack(alignment: .leading, spacing: 16) {
            Label("Deploy Blueprint", systemImage: "paperplane.fill")
                .font(.title2.weight(.semibold))
            Label("Devices in these groups receive every component of the Blueprint, including its App Settings.",
                  systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.tintedIcon(.orange))
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.changeNotice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .labelStyle(.tintedIcon(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deployChangeNotice")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(detail.overview.name).font(.headline)
                    Spacer()
                    if let state = detail.overview.deploymentState?.state { DeploymentStateBadge(state: state) }
                }
                Text(detail.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if model.groups.isEmpty {
                    Label(model.app.isJamfSchool
                          ? "No device groups in scope. A Blueprint without scope can’t be deployed; set the scope in Jamf School first."
                          : "No device groups in scope. A Blueprint without scope can’t be deployed; set the scope with Edit Scope… first.",
                          systemImage: "exclamationmark.triangle")
                        .labelStyle(.tintedIcon(.red))
                        .font(.callout)
                }
                ForEach(model.groups) { group in
                    HStack {
                        Image(systemName: "person.3")
                        Text(group.name)
                        Spacer()
                        if let count = group.memberCount {
                            Text("^[\(count) device](inflect: true)").monospacedDigit()
                        } else if !model.app.isJamfSchool {
                            Text("Count unknown").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                if model.app.isJamfSchool && !model.groups.isEmpty {
                    Text("Jamf School: the API doesn’t provide device group names or member counts. Check the groups in Jamf School before deploying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS Allow List Without the Recommended Baseline", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .labelStyle(.tintedIcon(.orange))
                    ForEach(warnings, id: \.self) { Text($0).font(.callout) }
                    Toggle("I understand that binaries not on the allow list will be blocked.", isOn: $model.acknowledgesAllowListRisk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.hasUnsavedEditorChanges {
                Label("The rule set has unsaved edits for this Blueprint. They aren’t part of this deployment; write them first to include them.", systemImage: "pencil.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $model.isConfirmed) {
                if let count = model.deviceCount {
                    Text("I confirm deploying “\(detail.overview.name)” to ^[\(count) device](inflect: true).")
                } else {
                    Text("I confirm deploying “\(detail.overview.name)” to the groups above.")
                }
            }
            .disabled(model.groups.isEmpty)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Deploy", role: .destructive) { model.deploy() }
                    .disabled(model.blockingReason != nil)
            }
        }
        .padding(24)
    }
}

private struct StatusView: View {
    let name: String
    let status: JamfPlatform.DeploymentStatus?
    let isFinal: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Deployment").foregroundStyle(.secondary)
                    Text(status?.jobState.map(Self.title) ?? "Waiting for Jamf to register it…")
                }
                GridRow {
                    Text("Blueprint").foregroundStyle(.secondary)
                    Text(status?.blueprintState?.displayName ?? "Unknown")
                }
                if let started = status?.jobStarted {
                    GridRow {
                        Text("Started").foregroundStyle(.secondary)
                        Text(JamfPlatform.date(from: started)?.formatted(date: .abbreviated, time: .standard) ?? started)
                    }
                }
                GridRow {
                    Text("Devices").foregroundStyle(.secondary)
                    if let report = status?.report {
                        Text("\(report.succeeded) succeeded · \(report.failed) failed · \(report.pending) pending").monospacedDigit()
                    } else {
                        Text("No status report yet").foregroundStyle(.secondary)
                    }
                }
                if let checked = status?.checkedAt {
                    GridRow {
                        Text("Checked").foregroundStyle(.secondary)
                        Text(checked.formatted(date: .omitted, time: .standard))
                    }
                }
            }
            .font(.callout)
            if isFinal && status?.isFinished != true {
                Text("The deployment hadn’t finished when the app stopped checking. It continues in Jamf; check the Blueprint later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if status?.report?.total == 0 {
                Text("No devices reported. The scoped groups have no members, or devices haven’t checked in yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(isFinal ? "Done" : "Stop Watching", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var header: some View {
        if !isFinal {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Deploying “\(name)”").font(.title3.weight(.semibold))
            }
        } else if status?.didSucceed == true {
            Label("Deployment Succeeded", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold)).labelStyle(.tintedIcon(.green))
        } else if status?.jobState == "FAILED" {
            Label("Deployment Failed", systemImage: "xmark.octagon.fill")
                .font(.title3.weight(.semibold)).labelStyle(.tintedIcon(.red))
        } else {
            Label("Deployment Still Running", systemImage: "clock")
                .font(.title3.weight(.semibold)).labelStyle(.tintedIcon(.orange))
        }
    }

    private nonisolated static func title(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

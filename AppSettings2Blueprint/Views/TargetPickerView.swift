import JTKit
import SwiftUI

/// "Write to Jamf": pick a new or existing Blueprint and a placement, review the
/// change, write it and show what Jamf returned.
struct TargetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: JamfWriteModel
    /// Set when "Deploy…" is chosen after a successful write.
    @State private var deployModel: DeployModel?

    init(app: AppModel) {
        _model = State(initialValue: JamfWriteModel(app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let deployModel {
                DeployFlowView(model: deployModel, close: {
                    deployModel.stopWatching()
                    dismiss()
                })
            } else {
            switch model.phase {
            case .choosing:
                ChooseTargetView(model: model, cancel: { dismiss() })
            case .preparing:
                ProgressPane(text: model.mode == .existing
                             ? "Checking the Blueprint, writing a backup and building the new steps…"
                             : "Creating the Blueprint…")
            case .review(let prepared):
                ReviewChangesSheet(model: model, prepared: prepared, cancel: { dismiss() })
            case .writing:
                ProgressPane(text: "Writing to Jamf and reading the Blueprint back…")
            case .done(let result):
                WriteResultView(result: result, done: { dismiss() }, deploy: {
                    deployModel = DeployModel(app: model.app, detail: result.detail)
                })
            case .failed(let message):
                FailureView(message: message, back: { model.backToChoosing() }, cancel: { dismiss() })
            case .uncertain(let message):
                UncertainWriteView(message: message, close: { dismiss() })
            }
            }
        }
        .frame(width: 820, height: 620)
        .task {
            if model.app.deviceGroups.isEmpty && !model.app.isJamfSchool { model.app.loadDeviceGroups() }
            if model.app.overviews.isEmpty { model.app.refresh() }
        }
        // Runs again whenever the list changes: a listing started above (or
        // a refresh) finishes after the sheet opened, and its Blueprints’
        // details are fetched then, instead of staying on "Loading…".
        .task(id: model.app.overviews.map(\.id)) {
            await model.app.loadMissingDetails()
        }
        .onChange(of: model.app.listState) { model.listDidChange() }
    }
}

// MARK: - Choose

private struct ChooseTargetView: View {
    @Bindable var model: JamfWriteModel
    let cancel: () -> Void

    var body: some View {
        let app = model.app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write to Jamf").font(.title3.weight(.semibold))
                    Text("“\(app.ruleSet.ruleSet.name)” · \(app.ruleSet.ruleSet.platform.displayName) · \(DeclarationEncoder.channels(for: app.ruleSet.ruleSet).joined(separator: " + ")) declaration\(model.declarations.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.canCreateBlueprints {
                    Picker("Target", selection: $model.mode) {
                        ForEach(JamfWriteModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                }
            }

            if !model.canCreateBlueprints {
                Banner(style: .info, text: "Jamf School: the API doesn’t list Jamf School device groups, so new Blueprints can’t be scoped here. Create the Blueprint in Jamf School, then write to it.")
            }

            switch model.mode {
            case .existing: ExistingTargetView(model: model)
            case .new: NewBlueprintView(model: model)
            }

            if !model.overlappingBlueprints.isEmpty {
                Banner(style: .warning, text: "Also scoped to these device groups with App Settings: \(model.overlappingBlueprints.map { "“\($0.overview.name)”" }.joined(separator: ", ")). Devices combine every App Settings declaration: AllowedApps and AllowedBinaries are intersected (only apps allowed by all of them run), DeniedApps and DeniedBinaries are combined. Check that they don’t conflict.")
            }

            Spacer(minLength: 0)
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
                Button(model.mode == .existing ? "Review Changes…" : "Create Blueprint") { model.prepare() }
                    .keyboardShortcut(model.primaryButtonIsDefault ? .defaultAction : nil)
                    .disabled(model.blockingReason != nil)
            }
        }
        .padding(16)
        // Jamf School is recognized once the device group list answers, which can
        // be after the sheet opened in New Blueprint mode.
        .onChange(of: app.isJamfSchool, initial: true) { _, isSchool in
            if isSchool { model.mode = .existing }
        }
    }
}

private struct ExistingTargetView: View {
    @Bindable var model: JamfWriteModel

    var body: some View {
        let app = model.app
        HStack(alignment: .top, spacing: 12) {
            List(app.overviews, selection: $model.selectedBlueprintID) { overview in
                let detail = app.details[overview.id]
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(overview.name).lineLimit(1)
                        Spacer()
                        if let state = overview.deploymentState?.state { DeploymentStateBadge(state: state) }
                    }
                    HStack(spacing: 6) {
                        if let detail {
                            if detail.containsAppSettings { Text("App Settings").foregroundStyle(.secondary) }
                            if app.isReadOnly(detail) { Label("Division (read-only)", systemImage: "lock").labelStyle(.tintedIcon(.orange)) }
                        } else if let error = app.detailErrors[overview.id] {
                            Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                                .labelStyle(.tintedIcon(.orange))
                                .help(error)
                            Button("Try Again") { app.loadDetail(id: overview.id) }
                                .buttonStyle(.link)
                        } else {
                            Text("Loading…").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
                .tag(overview.id)
            }
            .frame(width: 300)
            .overlay {
                if app.overviews.isEmpty {
                    ContentUnavailableView("No Blueprints", systemImage: "square.stack.3d.up.slash",
                                           description: Text(app.listState == .listing ? "Listing…" : "Create a new Blueprint instead."))
                }
            }

            if let detail = model.selectedDetail {
                PlacementView(model: model, detail: detail)
            } else {
                ContentUnavailableView("Choose a Blueprint", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PlacementView: View {
    @Bindable var model: JamfWriteModel
    let detail: JamfPlatform.BlueprintDetail

    var body: some View {
        let steps = detail.steps?.arrayValue ?? []
        let strict = detail.appSettingsLocations.filter(\.isStrictComponent)
        let others = detail.appSettingsLocations.filter { !$0.isStrictComponent }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(detail.overview.name).font(.headline)
                Text(scopeText).font(.caption).foregroundStyle(.secondary)
                if model.app.isReadOnly(detail) {
                    Banner(style: .error, text: JamfWriteModel.divisionText)
                }
                if detail.scopeDeviceGroups.isEmpty {
                    Banner(style: .error, text: JamfWriteModel.noScopeText(isJamfSchool: model.app.isJamfSchool))
                }

                Text("Placement").font(.subheadline.weight(.semibold))
                Picker("Placement", selection: Binding(
                    get: { model.effectivePlacement(for: detail) },
                    set: { model.placement = $0 }
                )) {
                    ForEach(strict) { location in
                        Text("Replace App Settings in step \(location.stepIndex + 1)\(location.stepName.map { " “\($0)”" } ?? ""), component \(location.componentIndex + 1)")
                            .tag(JamfWriteModel.Placement.replaceExisting(stepIndex: location.stepIndex, componentIndex: location.componentIndex))
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        let count = step["components"]?.arrayValue?.count ?? 0
                        Text("Add a component to step \(index + 1)\(step["name"]?.stringValue.map { " “\($0)”" } ?? "") (\(count) of \(AppSettingsLocator.maxComponentsPerStep) components)")
                            .tag(JamfWriteModel.Placement.appendToStep(index))
                    }
                    Text("Add a new step").tag(JamfWriteModel.Placement.newStep)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if case .newStep = model.effectivePlacement(for: detail) {
                    StepOptionsView(model: model)
                }
                if case .replaceExisting = model.effectivePlacement(for: detail) {
                    Text("Only the App Settings declarations in that component are replaced, channel by channel. Other declarations in it, and every other component, stay byte for byte as they are.")                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !others.isEmpty {
                    Banner(style: .info, text: "\(others.count) App Settings declaration\(others.count == 1 ? " is" : "s are") in components this app doesn’t edit (\(Set(others.map(\.componentIdentifier)).sorted().joined(separator: ", "))). They’re left unchanged.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scopeText: String {
        let groups = detail.scopeDeviceGroups
        guard !groups.isEmpty else { return "No device groups in scope" }
        return "Scope: " + groups.map(model.app.groupName).joined(separator: ", ")
    }
}

private struct NewBlueprintView: View {
    @Bindable var model: JamfWriteModel

    var body: some View {
        let app = model.app
        HStack(alignment: .top, spacing: 16) {
            Form {
                TextField("Name", text: $model.newName)
                TextField("Description", text: $model.newDescription, axis: .vertical)
                    .lineLimit(1...3)
                StepOptionsView(model: model)
                Text("Recommended: one Blueprint per platform. Use an activation predicate only to keep an iPadOS and a macOS rule set in one Blueprint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("Device groups (at least one)").font(.subheadline.weight(.semibold))
                List(app.deviceGroups) { group in
                    Toggle(isOn: Binding(
                        get: { model.selectedGroupIDs.contains(group.id) },
                        set: { if $0 { model.selectedGroupIDs.insert(group.id) } else { model.selectedGroupIDs.remove(group.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                            Text([group.deviceType.displayName, group.groupType.displayName,
                                  group.memberCount.map { "\($0) member\($0 == 1 ? "" : "s")" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .overlay {
                    if app.isLoadingDeviceGroups {
                        ProgressView()
                    } else if let error = app.deviceGroupsError {
                        ContentUnavailableView {
                            Label("Couldn’t Load Device Groups", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { app.loadDeviceGroups() }
                        }
                    } else if app.deviceGroups.isEmpty {
                        ContentUnavailableView("No Device Groups", systemImage: "person.3")
                    }
                }
            }
            .frame(width: 320)
        }
    }
}

private struct StepOptionsView: View {
    @Bindable var model: JamfWriteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Step name", text: $model.stepName)
            Toggle("Activation predicate", isOn: $model.usesActivationPredicate)
                .help("Limit the step to devices matching a predicate, so one Blueprint can hold an iPadOS and a macOS rule set")
            if model.usesActivationPredicate {
                TextField("Predicate", text: $model.activationPredicate, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...4)
            }
        }
    }
}

// MARK: - Progress, result, failure

private struct ProgressPane: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WriteResultView: View {
    let result: WriteResult
    let done: () -> Void
    let deploy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.isVerified {
                Label(result.created ? "Blueprint Created and Verified" : "Written and Verified", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
                    .labelStyle(.tintedIcon(.green))
                Text("Jamf returned exactly the component that was sent, and every other component is unchanged.")
                    .foregroundStyle(.secondary)
            } else {
                Label("Written, but the Read-Back Differs", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .labelStyle(.tintedIcon(.orange))
                ForEach(result.problems, id: \.self) { Text($0) }
            }
            HStack(spacing: 8) {
                Text("“\(result.detail.overview.name)”").font(.headline)
                if let state = result.detail.overview.deploymentState?.state { DeploymentStateBadge(state: state) }
            }
            Text("Nothing reaches devices until the Blueprint is deployed. Deploying is a separate, confirmed step.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Component as Returned by Jamf").font(.subheadline.weight(.semibold))
            MonospacedTextView(text: result.readBackComponent?.serializedString(pretty: true) ?? "Not found")
                .frame(maxHeight: .infinity)
            HStack {
                Text(result.detail.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                Spacer()
                Button("Deploy…", action: deploy)
                    .disabled(result.detail.scopeDeviceGroups.isEmpty)
                    .help("Deploy the Blueprint to its scope, after a confirmation")
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Nothing was sent, or Jamf refused the request: going back is safe.
private struct FailureView: View {
    let message: String
    let back: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing Was Written", systemImage: "xmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .labelStyle(.tintedIcon(.red))
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Close", role: .cancel, action: cancel)
                Button("Back", action: back).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// The write may have reached Jamf. No Back: repeating it could create a
/// second Blueprint. The Blueprint is fetched again in the background.
private struct UncertainWriteView: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Written, Not Verified", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .labelStyle(.tintedIcon(.orange))
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("The requests and Jamf’s answers are in the activity log (Window › Activity Log).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .accessibilityIdentifier("uncertainWrite")
    }
}

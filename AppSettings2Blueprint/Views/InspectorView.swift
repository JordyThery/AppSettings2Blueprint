import AppKit
import SwiftUI

/// Signing details for one inspected app or executable: what each identifier
/// matches, with copy buttons. It describes; it does not recommend.
struct InspectorView: View {
    @Environment(AppModel.self) private var app
    let path: String

    var body: some View {
        let model = app.localApps
        if let inspection = model.inspections[path] {
            InspectionDetail(inspection: inspection)
        } else if let error = model.inspectionErrors[path] {
            ContentUnavailableView {
                Label("Couldn't Read the Signature", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { model.inspect(path: path, force: true) }
            }
        } else {
            ProgressView("Reading signing information…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct InspectionDetail: View {
    @Environment(AppModel.self) private var app
    let inspection: InspectedBinary
    @State private var addingToAllowList: Bool?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = app.localApps
        let slices = model.showsAllArchitectures ? inspection.slices : inspection.defaultSlices
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ValueRow(label: "Bundle ID", value: inspection.bundleID)
                        ValueRow(label: "Version", value: inspection.version, monospaced: false, copyable: false)
                        ValueRow(label: "Composed Identifier", value: inspection.composedIdentifier)
                        ValueRow(label: "PathPrefix (suggested)", value: inspection.suggestedPathPrefix)
                        if model.showsAllArchitectures {
                            ValueRow(label: "Executable", value: inspection.executablePath)
                            ValueRow(label: "Designated Requirement", value: inspection.designatedRequirement)
                        }
                    }
                    .padding(4)
                }

                HStack {
                    Text("Signing")
                        .font(.headline)
                    Spacer()
                    Toggle("Show all architectures", isOn: $model.showsAllArchitectures)
                        .toggleStyle(.checkbox)
                        .help("Also show non–Apple silicon slices, the executable path and the designated requirement")
                }

                ForEach(slices) { slice in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.showsAllArchitectures || slices.count > 1 {
                                ValueRow(label: "Architecture", value: slice.architecture, copyable: false)
                            }
                            ValueRow(label: "CDHash", value: slice.cdHash)
                            ValueRow(label: "TeamID", value: slice.teamID)
                            ValueRow(label: "SigningID", value: slice.signingID)
                            ValueRow(label: "SigningState", value: slice.signingState.rawValue, copyable: slice.signingState != .unknown)
                            if model.showsAllArchitectures, slice.designatedRequirement != inspection.designatedRequirement {
                                ValueRow(label: "Designated Requirement", value: slice.designatedRequirement)
                            }
                        }
                        .padding(4)
                    }
                }

                notes(shownSlices: slices)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Adds this app to the rule set, or exports it in App Settings Utility's layout.
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Add to AllowedBinaries…", systemImage: "checkmark.shield") { addingToAllowList = true }
            Button("Add to DeniedBinaries…", systemImage: "nosign") { addingToAllowList = false }
            Button("Add Permission Defaults", systemImage: "hand.raised") {
                if let identifier = inspection.composedIdentifier {
                    app.ruleSet.addPermissionDefault(identifier: identifier, name: inspection.name, platform: .macOS)
                }
            }
            .disabled(inspection.composedIdentifier == nil)
            .help(inspection.composedIdentifier == nil
                  ? "Needs a bundle ID and a designated requirement to build the composed identifier"
                  : "Add a Privacy.PermissionDefaults entry keyed by the composed identifier")
            Spacer()
            Button("Export CSV…", systemImage: "tablecells") {
                do { try CSVExport.save(.localMacApps(LocalMacAppRow.rows(for: inspection))) } catch { errorMessage = error.localizedDescription }
            }
            .help("Save every slice as an App Settings Utility Local-Mac-Apps CSV")
        }
        .controlSize(.small)
        .sheet(item: Binding(
            get: { addingToAllowList.map { AddTarget(toAllowList: $0) } },
            set: { addingToAllowList = $0?.toAllowList }
        )) { target in
            AddBinaryRuleSheet(binary: inspection, toAllowList: target.toAllowList)
        }
        .alert("Couldn't Export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private struct AddTarget: Identifiable {
        let toAllowList: Bool
        var id: Bool { toAllowList }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: inspection.path))
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(inspection.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(inspection.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                verificationBadge
            }
            Spacer()
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: inspection.path)])
            }
            Button("Reload", systemImage: "arrow.clockwise") {
                app.localApps.inspect(path: inspection.path, force: true)
            }
        }
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch inspection.verification {
        case .valid:
            Label("Signature verification: Valid", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .unverified(let reason):
            Label("Signature verification: Unverified (\(reason))", systemImage: "xmark.seal.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func notes(shownSlices: [SliceSignature]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if inspection.composedIdentifier != nil {
                Text("The Composed Identifier can be copied directly into the declaration as a macOS PermissionDefaults key.")
            }
            if !inspection.hasAppleSiliconSlice {
                Text("No Apple silicon slice found; showing the available signing details.")
            }
            if inspection.slices.count > 1 {
                Text("Each architecture has its own CDHash. A CDHash rule matches one slice of this exact build only.")
            }
            Text("PathPrefix is a suggested app-folder restriction, not a signature field.")
            Text("Details describe the main executable; embedded helpers are not inspected.")
            if shownSlices.contains(where: { $0.signingState == .unknown }) {
                Text("SigningState could not be established. Unknown is not a declaration value.")
            }
            Text("The app is only read, never launched.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labelled value with an optional copy button. Missing values read "Unavailable";
/// nothing is ever filled in.
struct ValueRow: View {
    let label: String
    let value: String?
    var monospaced = true
    var copyable = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            if let value {
                Text(value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy \(label)")
                }
            } else {
                Text("Unavailable")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

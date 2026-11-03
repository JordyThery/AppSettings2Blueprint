import AppKit
import JTKit
import SwiftUI

/// The review before a write: the component before and after as a diff, what
/// else stays unchanged, and the backup. Nothing is sent until "Write to Blueprint".
struct ReviewChangesSheet: View {
    let model: JamfWriteModel
    let prepared: PreparedWrite
    let cancel: () -> Void
    @State private var showsPatchBody = false

    var body: some View {
        let edit = prepared.edit
        let diff = prepared.diff
        let changed = prepared.changedLineCount
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Changes").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("“\(prepared.name)” · \(placementText(edit.target)) · \(changed) changed line\(changed == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Text("\(edit.unchangedComponentCount) other component\(edit.unchangedComponentCount == 1 ? "" : "s") unchanged, byte for byte\(edit.otherAppSettings.isEmpty ? "" : "; \(edit.otherAppSettings.count) App Settings declaration\(edit.otherAppSettings.count == 1 ? "" : "s") elsewhere left as they are").")
                    .font(.callout)
            }
            .padding()

            Picker("Show", selection: $showsPatchBody) {
                Text("Component Diff").tag(false)
                Text("Exact PATCH Body").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()
            if showsPatchBody {
                MonospacedTextView(text: (try? LosslessJSON(data: prepared.patchBody))?.serializedString(pretty: true) ?? "")
            } else if changed == 0 {
                ContentUnavailableView("No Differences", systemImage: "equal.circle",
                                       description: Text("The Blueprint already holds exactly this rule set. Writing would change nothing."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(lines: diff)
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Backup written: \(prepared.backupURL.lastPathComponent)")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([prepared.backupURL]) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                Text("Writing sends PATCH with only {\"steps\": [...]}, the complete array, as application/merge-patch+json. The Blueprint is checked for changes once more first, then read back and compared. It shows Out of Date until deployed; deploying is a separate step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back") { model.backToChoosing() }
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Write to Blueprint") { model.commit(prepared) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(changed == 0)
                }
            }
            .padding()
        }
    }

    private func placementText(_ target: AppSettingsTarget) -> String {
        switch target {
        case let .existingComponent(step, component): "replace step \(step + 1), component \(component + 1)"
        case let .newComponent(step): "new component in step \(step + 1)"
        case let .newStep(name, predicate): "new step “\(name)”\(predicate == nil ? "" : " with an activation predicate")"
        }
    }
}

/// Lines of a diff, with removed lines in red and added lines in green. Lines
/// never wrap: long ones scroll sideways, and every row is at least as wide as
/// the visible area, so the colored rows reach the edge.
struct DiffView: View {
    let lines: [DiffLine]
    /// The visible width, measured; the rows' minimum width.
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 6) {
                        Text(marker(line.kind))
                            .foregroundStyle(color(line.kind))
                            .frame(width: 12)
                            .accessibilityLabel(markerName(line.kind))
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .unchanged ? .secondary : .primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .frame(minWidth: viewportWidth, alignment: .leading)
                    .background(color(line.kind).opacity(line.kind == .unchanged ? 0 : 0.12))
                    .accessibilityElement(children: .combine)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewportWidth = $0 }
        .accessibilityIdentifier("reviewDiff")
    }

    private func markerName(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .unchanged: "Unchanged"
        case .removed: "Removed"
        case .added: "Added"
        }
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .unchanged: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: .clear
        case .removed: .red
        case .added: .green
        }
    }
}

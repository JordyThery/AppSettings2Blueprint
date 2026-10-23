import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Raw JSON view: the GET response exactly as received, or pretty-printed.
/// The PATCH body a write will send is shown in the review sheet instead.
struct RawJSONView: View {
    let detail: BlueprintDetail

    @State private var format: Format = .pretty

    enum Format: String, CaseIterable, Identifiable {
        case pretty = "Pretty"
        case exact = "Exact Response"
        var id: String { rawValue }
    }

    private var data: Data {
        switch format {
        case .pretty: detail.json.serialized(pretty: true)
        case .exact: detail.rawData
        }
    }

    var body: some View {
        let data = data
        VStack(spacing: 0) {
            HStack {
                Picker("Format", selection: $format) {
                    ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Text("\(data.count.formatted(.byteCount(style: .file))) · fetched \(detail.fetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
                Button("Save…", systemImage: "square.and.arrow.down") {
                    save(data)
                }
            }
            .padding(8)
            Divider()
            MonospacedTextView(text: String(decoding: data, as: UTF8.self))
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let safeName = detail.overview.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Name, state and timestamps of a blueprint.
struct BlueprintHeader: View {
    let detail: BlueprintDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.overview.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let state = detail.overview.deploymentState?.state {
                    DeploymentStateBadge(state: state)
                }
            }
            if let updated = detail.overview.updated {
                Text("Updated \(detail.overview.updatedDate?.formatted(date: .abbreviated, time: .standard) ?? updated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(updated)
            }
            if let deployment = detail.overview.deploymentState,
               let started = deployment.lastDeploymentStarted {
                Text("Last deployment \(PlatformDate.parse(started)?.formatted(date: .abbreviated, time: .shortened) ?? started)\(deployment.lastDeploymentState.map { " · \(DeploymentStateKind(rawValue: $0).displayName)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(started)
            }
            Text(detail.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import AppKit
import JTKit
import SwiftUI

/// Lists local backups of a blueprint and PATCHes the chosen backup's steps back.
struct RestoreBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let detail: JamfPlatform.BlueprintDetail
    @State private var backups: [BlueprintBackup] = []
    @State private var selection: BlueprintBackup.ID?
    @State private var isConfirming = false
    @State private var isRestoring = false
    @State private var message: (text: String, isError: Bool)?

    private var selectedBackup: BlueprintBackup? {
        backups.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore from Backup").font(.title3.weight(.semibold))
                Text("A backup of “\(detail.overview.name)” is written before every change. Restoring sends the backup's steps with PATCH; the current server state is backed up first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            List(backups, selection: $selection) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.date.formatted(date: .abbreviated, time: .standard))
                        Text(backup.url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(backup.size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(backup.id)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                }
            }
            .overlay {
                if backups.isEmpty {
                    ContentUnavailableView("No Backups", systemImage: "clock.arrow.circlepath", description: Text("Backups appear here after the first write."))
                }
            }

            Divider()

            HStack {
                if isRestoring { ProgressView().controlSize(.small) }
                if let message {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(message.isError ? .red : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore…") { isConfirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedBackup == nil || isRestoring || model.isReadOnly(detail))
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .onAppear { backups = BackupStore.backups(for: detail.id) }
        .confirmationDialog(
            "Restore “\(detail.overview.name)” from this backup?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let backup = selectedBackup { restore(backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The blueprint's steps are replaced with those from \(selectedBackup?.date.formatted(date: .abbreviated, time: .standard) ?? "the backup"). Deploy afterwards to apply them to devices.")
        }
    }

    private func restore(_ backup: BlueprintBackup) {
        isRestoring = true
        message = nil
        Task {
            defer { isRestoring = false }
            do {
                let result = try await BlueprintWriter(service: model.currentService()).restore(backup, loaded: detail)
                model.storeDetail(result.detail)
                backups = BackupStore.backups(for: detail.id)
                message = result.isVerified
                    ? ("Restored and verified. Devices receive the restored state at the next deployment.", false)
                    : (result.problems.joined(separator: " "), true)
            } catch {
                if case BlueprintWriter.WriteError.readOnly = error { model.readOnlyBlueprintIDs.insert(detail.id) }
                message = (error.localizedDescription, true)
            }
        }
    }
}

import AppKit
import JTKit
import SwiftUI

/// Lists local backups of a Blueprint and PATCHes the chosen backup's steps back.
struct RestoreBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The Blueprint as the sheet opened; `current` is what the app holds now.
    let detail: JamfPlatform.BlueprintDetail
    @State private var backups: [BlueprintBackup] = []
    @State private var selection: BlueprintBackup.ID?
    @State private var isConfirming = false
    @State private var isRestoring = false
    @State private var message: (text: String, isError: Bool)?
    /// The connection the sheet was opened for; nothing is sent after it changed.
    @State private var connectionGeneration: Int?
    /// This sheet's waits before a retry, with Stop in its banner.
    @State private var waits = RequestWaits()

    private var selectedBackup: BlueprintBackup? {
        backups.first { $0.id == selection }
    }

    /// The latest copy the app has, so a second restore in the same sheet
    /// compares against the state the first one left, not the one it opened with.
    private var current: JamfPlatform.BlueprintDetail {
        model.details[detail.id] ?? detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RetryWaitBanner(waits: waits)
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore from Backup").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("A backup of “\(detail.overview.name)” is written before every change. Restoring sends the backup’s steps with PATCH; the current state in Jamf is backed up first.")
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
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.caption)
                        .labelStyle(.tintedIcon(message.isError ? .orange : .green))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore…") { isConfirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedBackup == nil || isRestoring || model.isReadOnly(current))
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .onChange(of: message?.text) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onAppear {
            backups = BackupStore.backups(for: detail.id, root: model.backupRoot)
            if connectionGeneration == nil { connectionGeneration = model.connectionGeneration }
        }
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
            Text("The Blueprint’s steps are replaced with those from \(selectedBackup?.date.formatted(date: .abbreviated, time: .standard) ?? "the backup"). Deploy afterwards to apply them to devices.")
        }
    }

    private func restore(_ backup: BlueprintBackup) {
        isRestoring = true
        message = nil
        let loaded = current
        Task {
            defer { isRestoring = false }
            do {
                guard model.connectionGeneration == connectionGeneration else { throw ConnectionChanged() }
                let result = try await model.makeWriter(waits: waits).restore(backup, loaded: loaded)
                if let connectionGeneration { model.storeDetail(result.detail, generation: connectionGeneration) }
                message = result.isVerified
                    ? ("Restored and verified. Devices receive the restored state at the next deployment.", false)
                    : (result.problems.joined(separator: " "), true)
            } catch let error as BlueprintWriter.WriteError where error.mayHaveWritten {
                model.reloadAfterUncertainWrite(id: detail.id, generation: connectionGeneration ?? -1)
                message = (error.localizedDescription, true)
            } catch is CancellationError {
                message = ("You stopped waiting for Jamf, so nothing was restored.", true)
            } catch {
                if case BlueprintWriter.WriteError.readOnly = error, model.connectionGeneration == connectionGeneration {
                    model.readOnlyBlueprintIDs.insert(detail.id)
                }
                // The next restore starts from the Blueprint as it is now.
                if case let BlueprintWriter.WriteError.changedOnServer(_, _, _, latest) = error, let connectionGeneration {
                    model.storeDetail(latest, generation: connectionGeneration)
                }
                message = (error.localizedDescription, true)
            }
            // A backup of the state before the restore was written either way.
            backups = BackupStore.backups(for: detail.id, root: model.backupRoot)
        }
    }
}

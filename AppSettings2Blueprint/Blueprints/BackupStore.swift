import Foundation
import JTKit

/// One backup file of a Blueprint (JTKit's `TimestampedBackup`; its key is
/// the Blueprint ID).
typealias BlueprintBackup = TimestampedBackup

/// The full JamfPlatform.BlueprintDetail JSON, written before every PATCH to
/// `~/Library/Application Support/AppSettings2Blueprint/Backups/<blueprintId>/<timestamp>.json`
/// by JTKit's `TimestampedBackupStore` (the folder and file names earlier
/// versions used, so their backups stay listed). A backup holds the whole
/// Blueprint as Jamf returned it, other components' settings included (Wi-Fi
/// passwords, certificates), so folders and files are readable by the user's
/// account only. Restoring needs those exact bytes, so nothing is masked.
nonisolated enum BackupStore {
    struct BackupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    /// How long backups are kept (Settings › General); JTKit's choices.
    typealias Retention = BackupRetention

    /// Where the choice is saved, as days; 0 is forever.
    static let retentionKey = "backupRetentionDays"

    /// The usual folder; under the live-check switch (JTKit's `LiveLaunch`)
    /// the run's own folder, so a release check never writes to `Backups/`.
    static var rootURL: URL {
        if let folder = LiveLaunch.appFilesFolder("Backups") { return folder }
        return URL.applicationSupportDirectory
            .appending(path: "AppSettings2Blueprint", directoryHint: .isDirectory)
            .appending(path: "Backups", directoryHint: .isDirectory)
    }

    static func store(root: URL = rootURL) -> TimestampedBackupStore {
        TimestampedBackupStore(root: root)
    }

    /// The folder of one Blueprint's backups; an unsafe ID ("", ".", "..")
    /// stays inside `root`.
    static func directory(for blueprintID: String, root: URL = rootURL) -> URL {
        store(root: root).directory(for: blueprintID)
    }

    /// Writes the exact bytes of `detail` as received from the server.
    @discardableResult
    static func write(_ detail: JamfPlatform.BlueprintDetail, date: Date = Date(), root: URL = rootURL) throws -> URL {
        try store(root: root).write(detail.rawData, for: detail.id, date: date)
    }

    /// Backups for one Blueprint, newest first.
    static func backups(for blueprintID: String, root: URL = rootURL) -> [BlueprintBackup] {
        store(root: root).backups(for: blueprintID)
    }

    /// Removes backups older than `retention`, keeping each Blueprint's
    /// newest one. Returns how many were removed.
    @discardableResult
    static func prune(_ retention: Retention, root: URL = rootURL, now: Date = Date()) -> Int {
        store(root: root).prune(retention, now: now)
    }

    static func load(_ backup: BlueprintBackup) throws -> JamfPlatform.BlueprintDetail {
        let data = try Data(contentsOf: backup.url)
        let detail = try JamfPlatform.BlueprintDetail(data: data)
        guard detail.id == backup.key else {
            throw BackupError(message: "The backup belongs to Blueprint \(detail.id), not \(backup.key).")
        }
        return detail
    }
}

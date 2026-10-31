import Foundation
import JTKit

nonisolated struct BlueprintBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let blueprintID: String
    let date: Date
    let size: Int

    var id: URL { url }
}

/// Writes the full JamfPlatform.BlueprintDetail JSON before every PATCH to
/// `~/Library/Application Support/AppSettings2Blueprint/Backups/<blueprintId>/<timestamp>.json`.
/// A backup holds the whole Blueprint as Jamf returned it, other components'
/// settings included (Wi-Fi passwords, certificates), so folders and files are
/// readable by the user's account only. Restoring needs those exact bytes, so
/// nothing in them is masked.
nonisolated enum BackupStore {
    struct BackupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long backups are kept (Settings › General). Saved as days; 0 is forever.
    enum Retention: Int, CaseIterable, Identifiable, Sendable {
        case forever = 0
        case oneYear = 365
        case ninetyDays = 90
        case thirtyDays = 30

        static let key = "backupRetentionDays"

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .forever: "Forever"
            case .oneYear: "1 Year"
            case .ninetyDays: "90 Days"
            case .thirtyDays: "30 Days"
            }
        }
    }

    /// Removes backups older than `retention`, keeping each Blueprint's newest
    /// one whatever its age (the state before its last write). Returns how
    /// many were removed.
    @discardableResult
    static func prune(_ retention: Retention, root: URL = rootURL, now: Date = Date()) -> Int {
        guard retention != .forever,
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retention.rawValue, to: now),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for folder in folders {
            for backup in backups(for: folder.lastPathComponent, root: root).dropFirst() where backup.date < cutoff {
                if (try? FileManager.default.removeItem(at: backup.url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    static var rootURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "AppSettings2Blueprint", directoryHint: .isDirectory)
            .appending(path: "Backups", directoryHint: .isDirectory)
    }

    static func directory(for blueprintID: String, root: URL = rootURL) -> URL {
        let safe = blueprintID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return root.appending(path: safe, directoryHint: .isDirectory)
    }

    /// File names sort chronologically and contain no colons: `2026-10-07T14-03-11.123Z.json`.
    private static let fileNameFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits).\(secondFraction: .fractional(3))Z",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    /// Writes the exact bytes of `detail` as received from the server.
    @discardableResult
    static func write(_ detail: JamfPlatform.BlueprintDetail, date: Date = Date(), root: URL = rootURL) throws -> URL {
        let directory = directory(for: detail.id, root: root)
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ownerOnly)
            // Also folders made by earlier versions, with the default permissions.
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: root.path(percentEncoded: false))
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path(percentEncoded: false))
            var url = directory.appending(path: "\(date.formatted(fileNameFormat)).json")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                url = directory.appending(path: "\(date.formatted(fileNameFormat))-\(counter).json")
                counter += 1
            }
            // `.withoutOverwriting` creates the file exclusively, so an existing
            // backup is never replaced. Foundation rejects it combined with `.atomic`.
            try detail.rawData.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
            return url
        } catch {
            throw BackupError(message: "Couldn’t write a backup to \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// Backups for one blueprint, newest first.
    static func backups(for blueprintID: String, root: URL = rootURL) -> [BlueprintBackup] {
        let directory = directory(for: blueprintID, root: root)
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return BlueprintBackup(
                    url: url,
                    blueprintID: blueprintID,
                    date: values?.creationDate ?? .distantPast,
                    size: values?.fileSize ?? 0
                )
            }
            // Numeric comparison of the name without ".json", so a same-millisecond
            // "-2" counter sorts after its base name instead of before it.
            .sorted {
                $0.url.deletingPathExtension().lastPathComponent
                    .compare($1.url.deletingPathExtension().lastPathComponent, options: .numeric) == .orderedDescending
            }
    }

    static func load(_ backup: BlueprintBackup) throws -> JamfPlatform.BlueprintDetail {
        let data = try Data(contentsOf: backup.url)
        let detail = try JamfPlatform.BlueprintDetail(data: data)
        guard detail.id == backup.blueprintID else {
            throw BackupError(message: "The backup belongs to Blueprint \(detail.id), not \(backup.blueprintID).")
        }
        return detail
    }
}

import Foundation

/// An .app bundle found by a scan, or a file the user dropped or chose.
nonisolated struct LocalAppEntry: Hashable, Sendable, Identifiable {
    let name: String
    let path: String

    var id: String { path }
    var url: URL { URL(filePath: path) }
}

/// Finds .app bundles in the standard application folders.
nonisolated enum LocalAppScanner {
    /// Anthony's three search folders.
    static let defaultFolders = [
        "/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications",
    ]

    static var userApplicationsFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path(percentEncoded: false)
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — scan_local_apps in appSettingsUtility.sh
    /// Walks each folder like `find -P <root> -type d -name '*.app' -prune`: symbolic
    /// links are not followed, and the walk stops at each .app instead of descending
    /// into it. Results are unique by path and sorted by name, case-insensitively.
    static func scan(folders: [String]) -> [LocalAppEntry] {
        var found: [String: LocalAppEntry] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                  let enumerator = FileManager.default.enumerator(
                      at: URL(filePath: folder, directoryHint: .isDirectory),
                      includingPropertiesForKeys: keys,
                      options: [],
                      errorHandler: { _, _ in true }
                  ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path(percentEncoded: false)
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                found[trimmed] = LocalAppEntry(name: url.deletingPathExtension().lastPathComponent, path: trimmed)
            }
        }
        return found.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    /// An entry for a dropped or chosen item: an .app bundle or a bare Mach-O executable.
    /// Returns nil for anything else.
    static func entry(for url: URL) -> LocalAppEntry? {
        let url = url.standardizedFileURL
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "app" else { return nil }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            return LocalAppEntry(name: url.deletingPathExtension().lastPathComponent, path: trimmed)
        }
        guard !MachOSlices.slices(at: url).isEmpty else { return nil }
        return LocalAppEntry(name: url.lastPathComponent, path: path)
    }
}

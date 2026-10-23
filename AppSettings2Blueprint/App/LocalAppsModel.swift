import Foundation
import Observation

/// State for Lookup → Local Mac Apps: scan results, added files and inspections.
@Observable
final class LocalAppsModel {
    static let includeUserApplicationsKey = "includeUserApplicationsFolder"

    private(set) var scanned: [LocalAppEntry] = []
    /// Items dropped onto the window or picked with Choose…, newest first.
    private(set) var added: [LocalAppEntry] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var inspections: [String: InspectedBinary] = [:]
    private(set) var inspectionErrors: [String: String] = [:]
    private(set) var inspectingPaths: Set<String> = []
    /// Dropped items that are neither an .app nor a Mach-O executable.
    var rejectedDrops: [String] = []

    var searchText = ""
    var selectedPath: String? {
        didSet { if let selectedPath { inspect(path: selectedPath) } }
    }
    var showsAllArchitectures = false
    var includesUserApplications = UserDefaults.standard.bool(forKey: LocalAppsModel.includeUserApplicationsKey) {
        didSet {
            UserDefaults.standard.set(includesUserApplications, forKey: Self.includeUserApplicationsKey)
            if hasScanned { scan() }
        }
    }

    var folders: [String] {
        LocalAppScanner.defaultFolders + (includesUserApplications ? [LocalAppScanner.userApplicationsFolder] : [])
    }

    var visibleScanned: [LocalAppEntry] { filter(scanned) }
    var visibleAdded: [LocalAppEntry] { filter(added) }

    func entry(path: String) -> LocalAppEntry? {
        added.first { $0.path == path } ?? scanned.first { $0.path == path }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let folders = folders
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                LocalAppScanner.scan(folders: folders)
            }.value
            scanned = results
            isScanning = false
            hasScanned = true
        }
    }

    /// Adds dropped or chosen files and selects the first one that was accepted.
    func add(urls: [URL]) {
        var firstAccepted: String?
        for url in urls {
            guard let entry = LocalAppScanner.entry(for: url) else {
                rejectedDrops.append(url.lastPathComponent)
                continue
            }
            added.removeAll { $0.path == entry.path }
            added.insert(entry, at: 0)
            // Re-inspect: a dropped file may have changed since it was last read.
            inspections[entry.path] = nil
            firstAccepted = firstAccepted ?? entry.path
        }
        if let firstAccepted { selectedPath = firstAccepted }
    }

    func removeAdded(path: String) {
        added.removeAll { $0.path == path }
        if selectedPath == path { selectedPath = nil }
    }

    /// Reads the signature off the main actor. Results are cached per path.
    func inspect(path: String, force: Bool = false) {
        guard force || (inspections[path] == nil && inspectionErrors[path] == nil),
              !inspectingPaths.contains(path) else { return }
        inspectingPaths.insert(path)
        inspectionErrors[path] = nil
        Task {
            let url = URL(filePath: path)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CodeSignatureInspector.inspect(url) }
            }.value
            switch result {
            case .success(let inspection): inspections[path] = inspection
            case .failure(let error): inspectionErrors[path] = error.localizedDescription
            }
            inspectingPaths.remove(path)
        }
    }

    private func filter(_ entries: [LocalAppEntry]) -> [LocalAppEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || inspections[$0.path]?.bundleID?.localizedCaseInsensitiveContains(query) == true
        }
    }
}

import Foundation

/// Settings domains for tests, kept out of Preferences. A named domain
/// (`UserDefaults(suiteName: "be.jordythery.appsettings2blueprint.tests.<UUID>")`)
/// can leave one file per test in Preferences when the host ends without
/// removing it. Here a domain is a file path in this test process's own
/// folder in the temporary folder (UserDefaults stores it there), and the
/// folder is removed when the process ends. Folders of processes that ended
/// without removing theirs (a crash) are removed by the next test run. The
/// same as Checkpoint's and Intune Deployer's.
nonisolated enum TestSettings {
    static let root = FileManager.default.temporaryDirectory
        .appending(path: "AppSettings2BlueprintTests-settings", directoryHint: .isDirectory)

    /// This process's folder, made once; the first use also removes the
    /// folders of ended test processes and arranges removal of this one.
    static let folder: URL = {
        removeEndedProcessFolders()
        let folder = root.appending(path: "\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit {
            try? FileManager.default.removeItem(at: TestSettings.root.appending(path: "\(getpid())"))
        }
        return folder
    }()

    /// Removes the folders of test processes that have ended.
    static func removeEndedProcessFolders() {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let pid = Int32(name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fileManager.removeItem(at: root.appending(path: name))
        }
    }

    /// A new, empty domain; never the app's real settings.
    static func makeDefaults(_ purpose: String = "settings") -> (domain: String, defaults: UserDefaults) {
        let domain = folder.appending(path: "\(purpose)-\(UUID().uuidString)").path
        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("A test's settings domain couldn’t be opened: \(domain)")
        }
        defaults.removePersistentDomain(forName: domain)
        return (domain, defaults)
    }
}

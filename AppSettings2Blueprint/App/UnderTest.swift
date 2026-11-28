import Foundation
import JTKit
import os

/// Under tests the app makes no request to a saved connection and reads no
/// saved setting or Keychain item. "Under tests" is the host of the unit
/// tests and a sandbox launch (`-JTKitSandbox YES`, which the UI tests use),
/// as JTKit's `TestRun.isActive` says. Both start with settings and secrets
/// of their own (`AppModel.forLaunch()`), so the saved connections aren't
/// even read; a model that is still given them (`ProfileStore`'s
/// `holdsSavedConnections`) gets a network that refuses every request, sign-in
/// included, before it's sent and writes it down, so the release check can
/// show it in its report and fail. Demo Mode isn't a tenant: it's answered
/// inside the app and never refused.
nonisolated enum UnderTest {
    /// Whether this launch is under tests (JTKit's `TestRun.isActive`).
    static var isActive: Bool { TestRun.isActive }

    /// Where refused attempts are written: a folder in the user's temporary
    /// folder, the same for the test host and the app the UI tests launch.
    /// The release check empties it before every run.
    static let folder = TestRun.attemptsFolder(named: "AppSettings2Blueprint-under-test")

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: the release check never sends a request to a saved connection."

    /// The network for the saved connections while under tests: every
    /// request, sign-in included, is refused before it's sent and written to
    /// `log`. Nothing leaves the Mac.
    static func refusingSession(log: TestRun.AttemptLog = .savedConnections) -> URLSession {
        TestRun.refusingSession(log: log, message: refusal)
    }

    /// The settings of the unit-test host and of Xcode previews: a throwaway
    /// domain in the temporary folder, emptied when it's opened (never the
    /// saved settings, and no file in Preferences).
    static func throwawayDefaults(named name: String) -> UserDefaults {
        let domain = FileManager.default.temporaryDirectory.appending(path: "AppSettings2Blueprint-\(name)").path
        // Never the saved settings as a fallback: stop instead.
        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("The \(name) settings domain couldn’t be opened: \(domain)")
        }
        defaults.removePersistentDomain(forName: domain)
        return defaults
    }
}

extension TestRun.AttemptLog {
    nonisolated private static let logger = Logger(subsystem: "be.jordythery.appsettings2blueprint", category: "UnderTest")

    /// Requests to a saved connection: method, host and path only, never the
    /// query.
    nonisolated static let savedConnections = TestRun.AttemptLog(
        fileURL: UnderTest.folder.appending(path: "saved-connection-requests.jsonl"), logger: logger)
}

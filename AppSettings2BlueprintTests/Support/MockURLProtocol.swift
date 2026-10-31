import AppKit
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

// The mock network itself (`MockURLProtocol`, `RecordedRequest`,
// `MockResponse`) is JTKitTestSupport's.

/// Parent of every suite that uses MockURLProtocol. Its handler is global, so all
/// nested suites run one at a time, never alongside each other.
@Suite(.serialized)
struct MockNetworkTests {}

/// Thread-safe counter for use inside `@Sendable` mock handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Increments and returns the new value (first call returns 1).
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Records requested sleeps instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var recorded: [Duration] { lock.withLock { durations } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { durations.append(duration) }
    }
}

/// App models for tests: settings in a throwaway suite, secrets in memory, and
/// the network a test passes in. Never the app's real preferences or Keychain.
@MainActor
enum TestApp {
    private static var suiteNames: [String] = []

    /// A fresh, empty settings suite of its own (tests run in parallel),
    /// removed when the test host quits.
    static func defaults() -> UserDefaults {
        let name = "be.jordythery.appsettings2blueprint.tests.\(UUID().uuidString)"
        if suiteNames.isEmpty {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated {
                    for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
                }
            }
        }
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// - Parameters:
    ///   - connected: with one complete saved connection in use (and its
    ///     secret), so requests go to `session`.
    ///   - backupRoot: where its backups go; a new temporary folder by default.
    static func model(session: URLSession = MockURLProtocol.makeSession(), connected: Bool = false,
                      backupRoot: URL = temporaryFolder()) -> AppModel {
        let defaults = defaults()
        let store = ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        if connected {
            let profile = ConnectionProfile(name: "Test", region: .eu, environmentID: testEnvironmentID, clientID: "client-1")
            try! store.connections.save(profile, secrets: [.main: "secret"])
            store.selectedProfileID = profile.id
        }
        return AppModel(profileStore: store, session: session, defaults: defaults, backupRoot: backupRoot)
    }

    /// A folder path in the temporary directory, not created yet.
    nonisolated static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "as2b-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

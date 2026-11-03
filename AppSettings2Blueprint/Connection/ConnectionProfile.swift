import Foundation
import JTKit

/// A saved tenant connection. The client secret is NOT stored here: it lives in the
/// Keychain, keyed by `id`.
///
/// Saved under the UserDefaults key `connectionProfiles` with these field names;
/// keep them, or saved connections are lost. The region is JTKit's `JamfRegion`,
/// saved as the same "us", "eu" or "apac".
nonisolated struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var region: JamfRegion
    var environmentID: String
    var clientID: String

    /// One of the release check's connections under the live-check switch
    /// (JTKit's `LiveLaunch`), kept in memory with its own ID.
    init(live connection: Connection) {
        self.init(id: connection.id, name: connection.name, region: connection.region,
                  environmentID: connection.environmentID, clientID: connection.clientID)
    }

    init(id: UUID = UUID(), name: String, region: JamfRegion, environmentID: String, clientID: String) {
        self.id = id
        self.name = name
        self.region = region
        self.environmentID = environmentID
        self.clientID = clientID
    }

    static func newProfile() -> ConnectionProfile {
        ConnectionProfile(name: "New Connection", region: .us, environmentID: "", clientID: "")
    }

    /// The name in the toolbar picker and the Connection menu, e.g. "Production (eu)".
    var menuTitle: String {
        "\(ConnectionMenuText.name(of: connection)) (\(region.rawValue))"
    }

    var isComplete: Bool {
        !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && environmentIDIssue == nil
    }
}

/// Everything the API client needs to talk to one tenant.
nonisolated struct PlatformCredentials: Sendable, Equatable {
    var region: JamfRegion
    var environmentID: String
    var clientID: String
    var clientSecret: String
    /// Shown with each entry in the activity log.
    var connectionName = ""

    /// The JTKit connection the Platform client is built from.
    var connection: Connection {
        Connection(name: connectionName, service: .jamfPlatform, region: region,
                   environmentID: environmentID, clientID: clientID)
    }
}

/// How JTKit's connections list and editor see a profile: a Jamf Platform API
/// connection. Only the name, region, Environment ID and client ID change.
nonisolated extension ConnectionProfile: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: .jamfPlatform,
                       region: region, environmentID: environmentID, clientID: clientID)
        }
        set {
            name = newValue.name
            region = newValue.region
            environmentID = newValue.environmentID
            clientID = newValue.clientID
        }
    }
}

nonisolated extension ConnectionProfile {
    /// The Environment ID must be a lowercase-or-uppercase UUID (the API's
    /// `X-Environment-Id` pattern). Returns a message describing the problem, or nil.
    var environmentIDIssue: String? {
        let value = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return UUID(uuidString: value) == nil
            ? "Not a UUID. Expected 8-4-4-4-12 hexadecimal characters, e.g. 12345678-1234-4123-8123-123456789abc."
            : nil
    }
}

import Foundation

/// Jamf Platform API region.
nonisolated enum PlatformRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case us
    case eu
    case apac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: "United States (us)"
        case .eu: "Europe (eu)"
        case .apac: "Asia Pacific (apac)"
        }
    }

    /// `https://{region}.api.jamfcloud.com`
    var baseURL: URL {
        URL(string: "https://\(rawValue).api.jamfcloud.com")!
    }
}

/// A saved tenant connection. The client secret is NOT stored here: it lives in the
/// Keychain, keyed by `id`.
nonisolated struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var region: PlatformRegion
    var environmentID: String
    var clientID: String

    static func newProfile() -> ConnectionProfile {
        ConnectionProfile(name: "New Connection", region: .us, environmentID: "", clientID: "")
    }

    var isComplete: Bool {
        !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && environmentIDIssue == nil
    }
}

/// Everything the API client needs to talk to one tenant.
nonisolated struct PlatformCredentials: Sendable, Equatable {
    var region: PlatformRegion
    var environmentID: String
    var clientID: String
    var clientSecret: String
}

nonisolated extension ConnectionProfile {
    /// The Environment ID must be a lowercase-or-uppercase UUID (the API's
    /// `X-Environment-Id` pattern). Returns a message describing the problem, or nil.
    var environmentIDIssue: String? {
        let value = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return UUID(uuidString: value) == nil
            ? "Not a UUID. Expected 8-4-4-4-12 hexadecimal characters, e.g. e77c1408-10c8-4007-b177-abc9157fbcaa."
            : nil
    }
}

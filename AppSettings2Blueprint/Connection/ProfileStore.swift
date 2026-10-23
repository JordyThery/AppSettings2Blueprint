import Foundation
import Observation

/// Persists connection profiles (without secrets) in UserDefaults and tracks the
/// active one. Secrets are read from and written to the Keychain on demand.
@Observable
final class ProfileStore {
    private static let profilesKey = "connectionProfiles"
    private static let selectedKey = "selectedConnectionProfileID"

    private(set) var profiles: [ConnectionProfile]
    var selectedProfileID: UUID? {
        didSet { UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: Self.selectedKey) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        let storedSelection = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init)
        // A stored selection that no longer matches a profile would read as "no connection".
        if let storedSelection, profiles.contains(where: { $0.id == storedSelection }) {
            selectedProfileID = storedSelection
        } else {
            selectedProfileID = profiles.first?.id
        }
    }

    var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    /// Inserts or updates a profile. Pass a secret to update the Keychain item;
    /// pass nil to leave the stored secret unchanged.
    func save(_ profile: ConnectionProfile, secret: String?) throws {
        if let secret {
            try KeychainStore.setSecret(secret, for: profile.id)
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if selectedProfileID == nil { selectedProfileID = profile.id }
        persist()
    }

    func delete(id: UUID) {
        KeychainStore.deleteSecret(for: id)
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        persist()
    }

    /// Nil when the profile is incomplete or has no stored secret; throws when the
    /// Keychain cannot be read, which is a different problem than "not configured".
    func credentials(for profile: ConnectionProfile) throws -> PlatformCredentials? {
        guard profile.isComplete, let secret = try KeychainStore.secret(for: profile.id), !secret.isEmpty else {
            return nil
        }
        return PlatformCredentials(
            region: profile.region,
            environmentID: profile.environmentID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientID: profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }
}

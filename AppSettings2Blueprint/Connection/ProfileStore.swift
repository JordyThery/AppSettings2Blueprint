import Foundation
import JTKit
import Observation
import os

/// The saved connection profiles and the active one. JTKit's `ConnectionStore`
/// keeps the profiles (without secrets) under the UserDefaults key
/// `connectionProfiles`, and their client secrets in the login
/// Keychain (service `AppSettings2Blueprint.client-secret`, account = profile
/// UUID). The active profile is saved under `selectedConnectionProfileID`.
@Observable
final class ProfileStore {
    static let profilesKey = "connectionProfiles"
    static let selectedKey = "selectedConnectionProfileID"

    let connections: ConnectionStore<ConnectionProfile>
    @ObservationIgnored private let defaults: UserDefaults

    var selectedProfileID: UUID? {
        didSet {
            // Under the live-check switch the release check's connections are
            // in memory only, and so is the choice between them.
            guard !LiveLaunch.isSwitched else { return }
            defaults.set(selectedProfileID?.uuidString, forKey: Self.selectedKey)
        }
    }

    /// - Parameters:
    ///   - defaults: where the profiles and the active one are saved.
    ///   - secrets: where client secrets are kept; the app's Keychain items by default.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = ProfileStore.keychain) {
        self.defaults = defaults
        let logger = Self.logger
        connections = ConnectionStore(
            storage: UserDefaultsConnectionStorage(key: Self.profilesKey, defaults: defaults),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { logger.error("\($0, privacy: .public)") },
            liveRecord: ConnectionProfile.init(live:)
        )
        let storedSelection = LiveLaunch.isSwitched ? nil : defaults.string(forKey: Self.selectedKey).flatMap(UUID.init)
        // A stored selection that no longer matches a profile would read as "no connection".
        if let storedSelection, connections.record(id: storedSelection) != nil {
            selectedProfileID = storedSelection
        } else {
            selectedProfileID = connections.records.first?.id
        }
    }

    /// The client secrets, as earlier versions of the app saved them.
    nonisolated static let keychain = KeychainSecretStore(
        service: "AppSettings2Blueprint.client-secret",
        label: "AppSettings2Blueprint client secret",
        log: { logger.error("\($0, privacy: .public)") }
    )

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.appsettings2blueprint", category: "connections")

    var profiles: [ConnectionProfile] { connections.records }

    var selectedProfile: ConnectionProfile? {
        selectedProfileID.flatMap(connections.record(id:))
    }

    /// A new profile for + in Settings › Connections. JTKit makes it the one
    /// in use once it's saved, when none is.
    func newProfile() -> ConnectionProfile {
        ConnectionProfile.newProfile()
    }

    /// After a profile was deleted in Settings: when it was the active one, the
    /// first remaining profile becomes active.
    func profileWasDeleted() {
        if selectedProfile == nil { selectedProfileID = profiles.first?.id }
    }

    /// The stored client secret, nil when there is none.
    /// - Throws: `SecretStoreError` when the Keychain refused or is locked:
    ///   that isn't the same as "no secret".
    func readSecret(for profile: ConnectionProfile) throws -> String? {
        try connections.readSecret(for: profile.connection)
    }

    /// What a sign-in needs.
    /// - Throws: `APIError.missingCredentials` when the profile is incomplete
    ///   or has no stored secret, `APIError.keychainUnreadable` when the
    ///   Keychain can't read it.
    func credentials(for profile: ConnectionProfile) throws -> PlatformCredentials {
        guard profile.isComplete else { throw APIError.missingCredentials }
        let secret: String?
        do {
            secret = try readSecret(for: profile)
        } catch let error as SecretStoreError {
            throw APIError.keychainUnreadable(connection: profile.menuTitle, status: error.status)
        }
        guard let secret, !secret.isEmpty else { throw APIError.missingCredentials }
        return PlatformCredentials(profile: profile, secret: secret)
    }
}

nonisolated extension PlatformCredentials {
    /// The profile's values and a secret, with surrounding spaces removed.
    init(profile: ConnectionProfile, secret: String) {
        self.init(
            region: profile.region,
            environmentID: profile.environmentID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientID: profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            connectionName: profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

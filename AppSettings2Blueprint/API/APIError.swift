import Foundation

/// The app's own errors. Errors from Jamf come as JTKit's `JamfPlatform.APIError`,
/// in the format every app shows: the HTTP status line, one
/// `CODE (field): description` line per error, the Trace ID and hints.
nonisolated enum APIError: Error, LocalizedError, Sendable {
    case missingCredentials
    /// The connection's client secret may be stored, but the Keychain refused
    /// to read it or is locked.
    case keychainUnreadable(connection: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No complete connection is configured. Open Settings and add a region, Environment ID, Client ID and Client Secret."
        case let .keychainUnreadable(connection, status):
            return "The client secret of “\(connection)” couldn’t be read from the Keychain (error \(status)). Unlock the login Keychain, or choose Allow when macOS asks, then try again."
        }
    }
}

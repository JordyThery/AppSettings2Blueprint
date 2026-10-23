import Foundation

/// Values for permissions that are either not set or allowed.
nonisolated enum PermissionAllowValue: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case allow = "Allow"
    var id: String { rawValue }
}

nonisolated enum LocationValue: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case whileUsing = "WhileUsing"
    case always = "Always"
    var id: String { rawValue }
}

nonisolated enum LocationAccuracyValue: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case approximate = "Approximate"
    case precise = "Precise"
    var id: String { rawValue }
}

/// The permissions a PermissionDefaults entry can set, with their platform limits.
nonisolated enum PermissionKey: String, CaseIterable, Identifiable, Sendable {
    case accessibility = "Accessibility"
    case bluetooth = "Bluetooth"
    case camera = "Camera"
    case dictation = "Dictation"
    case localNetwork = "LocalNetwork"
    case location = "Location"
    case locationAccuracy = "LocationAccuracy"
    case microphone = "Microphone"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: "Local Network"
        case .locationAccuracy: "Location Accuracy"
        default: rawValue
        }
    }

    /// Allowed values, from the declaration schema.
    var allowedValues: [String] {
        switch self {
        case .location: LocationValue.allCases.map(\.rawValue)
        case .locationAccuracy: LocationAccuracyValue.allCases.map(\.rawValue)
        default: PermissionAllowValue.allCases.map(\.rawValue)
        }
    }

    /// Accessibility is not supported on iOS; LocationAccuracy is not supported on macOS.
    func isSupported(on platform: RulePlatform) -> Bool {
        switch (self, platform) {
        case (.accessibility, .iOS), (.locationAccuracy, .macOS): false
        default: true
        }
    }
}

/// One entry of Privacy.PermissionDefaults. The key is the bundle ID on iOS and
/// the composed `Bundle-ID {Designated-Requirement}` identifier on macOS.
nonisolated struct PermissionDefault: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var appIdentifier = ""
    var organizationJustification = ""
    /// Set permissions only, keyed by `PermissionKey.rawValue`. A missing key is not written.
    var values: [String: String] = [:]
    var displayName: String?
    var extras = PreservedJSON()

    func value(_ key: PermissionKey) -> String? { values[key.rawValue] }

    mutating func setValue(_ value: String?, for key: PermissionKey) {
        values[key.rawValue] = value
    }
}

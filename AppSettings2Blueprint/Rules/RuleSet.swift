import Foundation

/// The device family a rule set targets. A rule set never mixes iOS-only and
/// macOS-only keys.
nonisolated enum RulePlatform: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case iOS
    case macOS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iOS: "iOS / iPadOS"
        case .macOS: "macOS"
        }
    }
}

/// Which of the two app lists the iOS tab edits.
nonisolated enum AppListMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case allow
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allow: "Allow list (AllowedApps)"
        case .deny: "Deny list (DeniedApps)"
        }
    }

    var key: String {
        switch self {
        case .allow: "AllowedApps"
        case .deny: "DeniedApps"
        }
    }
}

/// One bundle ID in AllowedApps or DeniedApps.
nonisolated struct AppRule: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var bundleID: String
    /// Shown in the editor only; never written to the declaration.
    var displayName: String?
}

/// Keys of one declaration that this app does not interpret, kept so they are
/// written back unchanged.
nonisolated struct PreservedDeclarationParts: Codable, Hashable, Sendable {
    /// Declaration members other than type, kind, channelType and payload.
    var declaration = PreservedJSON()
    /// Payload members other than Allowed and Privacy.
    var payload = PreservedJSON()
    var allowed = PreservedJSON()
    var privacy = PreservedJSON()

    var isEmpty: Bool { declaration.isEmpty && payload.isEmpty && allowed.isEmpty && privacy.isEmpty }
}

/// One App Settings rule set: the content of one com.apple.configuration.app.settings
/// declaration (on macOS, a SYSTEM declaration for binaries and a USER declaration
/// for privacy defaults).
nonisolated struct RuleSet: Codable, Hashable, Sendable {
    var name = "Untitled Rule Set"
    var platform: RulePlatform = .iOS

    // iOS / iPadOS
    var appListMode: AppListMode = .deny
    var allowedApps: [AppRule] = []
    var deniedApps: [AppRule] = []

    // macOS
    var allowedBinaries: [BinaryRule] = []
    var deniedBinaries: [BinaryRule] = []
    /// nil means the key is not written (the device default is false).
    var alwaysAllowManagedApps: Bool?

    var permissionDefaults: [PermissionDefault] = []

    /// Unknown keys, per channel ("SYSTEM" / "USER").
    var preserved: [String: PreservedDeclarationParts] = [:]

    var isEmpty: Bool {
        allowedApps.isEmpty && deniedApps.isEmpty && allowedBinaries.isEmpty && deniedBinaries.isEmpty
            && alwaysAllowManagedApps == nil && permissionDefaults.isEmpty
    }

    /// The list the iOS tab shows for the current mode.
    var currentAppList: [AppRule] {
        get { appListMode == .allow ? allowedApps : deniedApps }
        set { if appListMode == .allow { allowedApps = newValue } else { deniedApps = newValue } }
    }

    /// Adds bundle IDs to the current app list, skipping ones already in it.
    /// Returns how many were added.
    @discardableResult
    mutating func addApps(_ apps: [(bundleID: String, name: String?)]) -> Int {
        var list = currentAppList
        var known = Set(list.map { $0.bundleID.lowercased() })
        var added = 0
        for app in apps {
            let bundleID = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, known.insert(bundleID.lowercased()).inserted else { continue }
            list.append(AppRule(bundleID: bundleID, displayName: app.name))
            added += 1
        }
        currentAppList = list
        return added
    }

    /// Whether AllowedBinaries is set without the recommended baseline:
    /// AlwaysAllowManagedApps true and an Apple-signed `*APPLE*` entry.
    var isMissingAllowListBaseline: Bool {
        guard platform == .macOS, !allowedBinaries.isEmpty else { return false }
        return alwaysAllowManagedApps != true || !allowedBinaries.contains(where: \.isAppleBaseline)
    }

    /// Adds whatever part of the baseline is missing.
    mutating func addRecommendedBaseline() {
        alwaysAllowManagedApps = true
        if !allowedBinaries.contains(where: \.isAppleBaseline) {
            allowedBinaries.insert(.appleBaseline, at: 0)
        }
    }
}

/// A JSON object kept verbatim. Codable as its serialized text, so number literals
/// and key order survive a save to disk.
nonisolated struct PreservedJSON: Codable, Hashable, Sendable {
    var object: JSONObject

    init(_ object: JSONObject = JSONObject()) {
        self.object = object
    }

    var isEmpty: Bool { object.isEmpty }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let object = try JSONValue(string: text).objectValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Preserved JSON is not an object"))
        }
        self.object = object
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(JSONValue.object(object).serializedString())
    }
}

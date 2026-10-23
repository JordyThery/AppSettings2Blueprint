import Foundation

/// `SigningState` values from the declaration schema.
nonisolated enum SigningStateValue: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case testFlight = "TestFlight"
    case developerID = "DeveloperID"
    case enterprise = "Enterprise"
    case appStore = "AppStore"
    case apple = "Apple"

    var id: String { rawValue }
}

/// One BinaryIdentifier in AllowedBinaries or DeniedBinaries. Empty strings mean
/// "not set". `signingState` stays a string so an unrecognised value read from
/// Jamf is kept and reported, not dropped.
nonisolated struct BinaryRule: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var cdHash = ""
    var teamID = ""
    var signingID = ""
    var pathPrefix = ""
    var signingState = ""
    /// Where the rule came from (app name and architecture); never written.
    var sourceDescription: String?
    /// BinaryIdentifier keys this app does not know, written back unchanged.
    var extras = PreservedJSON()

    var hasCDHash: Bool { !trimmed(cdHash).isEmpty }
    var hasTeamID: Bool { !trimmed(teamID).isEmpty }
    var hasSigningID: Bool { !trimmed(signingID).isEmpty }

    /// `{"TeamID":"*APPLE*","SigningState":"Apple"}`: allows every Apple-signed binary.
    var isAppleBaseline: Bool {
        trimmed(teamID) == CodeSignatureInspector.appleTeamPlaceholder
            && trimmed(signingState) == SigningStateValue.apple.rawValue
            && !hasCDHash && !hasSigningID && trimmed(pathPrefix).isEmpty
    }

    static var appleBaseline: BinaryRule {
        BinaryRule(
            teamID: CodeSignatureInspector.appleTeamPlaceholder,
            signingState: SigningStateValue.apple.rawValue,
            sourceDescription: "Recommended baseline: every Apple-signed binary"
        )
    }

    /// The identifying fields only, for duplicate detection. The CDHash compares
    /// case-insensitively, so a pasted uppercase copy still counts as a duplicate.
    var matchKey: [String] {
        [trimmed(cdHash).lowercased()] + [teamID, signingID, pathPrefix, signingState].map(trimmed)
    }
}

private nonisolated func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// How a rule built from an inspected app matches binaries. Each strategy writes
/// only its own fields.
nonisolated enum BinaryMatchStrategy: String, CaseIterable, Identifiable, Hashable, Sendable {
    case exactBuild
    case appFromDeveloper
    case developer
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactBuild: "This exact build"
        case .appFromDeveloper: "This app from this developer"
        case .developer: "Everything from this developer"
        case .custom: "Custom"
        }
    }

    var fields: String {
        switch self {
        case .exactBuild: "CDHash"
        case .appFromDeveloper: "TeamID + SigningID"
        case .developer: "TeamID"
        case .custom: "Any valid combination"
        }
    }

    var tradeOff: String {
        switch self {
        case .exactBuild:
            "Matches only this build. It stops matching at the next update, and a universal app needs one rule per architecture slice."
        case .appFromDeveloper:
            "Matches this app signed by this team, across updates. Recommended for most rules."
        case .developer:
            "Matches every binary signed by this team. Broad."
        case .custom:
            "Choose the fields yourself, including PathPrefix and SigningState."
        }
    }

    /// The rules this strategy produces for `binary`, one per slice for exactBuild
    /// and a single rule otherwise. Empty when a required value is missing.
    func rules(for binary: InspectedBinary, slices: [SliceSignature]) -> [BinaryRule] {
        let source = { (slice: SliceSignature?) in
            [binary.name, slice.map(\.architecture)].compactMap { $0 }.joined(separator: " · ")
        }
        switch self {
        case .exactBuild:
            return slices.compactMap { slice in
                slice.cdHash.map { BinaryRule(cdHash: $0, sourceDescription: source(slice)) }
            }
        case .appFromDeveloper:
            guard let slice = slices.first, let team = slice.teamID, let signing = slice.signingID else { return [] }
            return [BinaryRule(teamID: team, signingID: signing, sourceDescription: source(nil))]
        case .developer:
            guard let team = slices.first?.teamID else { return [] }
            return [BinaryRule(teamID: team, sourceDescription: source(nil))]
        case .custom:
            return []
        }
    }

    /// Whether the inspected values make this strategy usable.
    func isAvailable(for binary: InspectedBinary) -> Bool {
        let slice = binary.defaultSlices.first
        switch self {
        case .exactBuild: return binary.slices.contains { $0.cdHash != nil }
        case .appFromDeveloper: return slice?.teamID != nil && slice?.signingID != nil
        case .developer: return slice?.teamID != nil
        case .custom: return true
        }
    }
}

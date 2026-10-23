import Foundation

/// One CSV cell as jq's `@csv` writes it: strings quoted, numbers and booleans
/// bare, null as an empty unquoted cell. Keeping the distinction makes an import
/// followed by an export byte-identical.
nonisolated enum CSVField: Hashable, Sendable {
    case text(String)
    case bare(String)
    case null

    /// The cell's value, or nil for an empty cell.
    var value: String? {
        switch self {
        case .text(let text): text.isEmpty ? nil : text
        case .bare(let text): text.isEmpty ? nil : text
        case .null: nil
        }
    }

    static func optionalText(_ value: String?) -> CSVField { value.map(CSVField.text) ?? .null }
}

/// App Settings Utility's two CSV layouts.
nonisolated enum CSVFormat: String, CaseIterable, Identifiable, Sendable {
    case bundleIDLookup
    case localMacApps

    var id: String { rawValue }

    // Ported from cantscript/AppSettingsUtility (MIT) — create_csv and export_local_csv in appSettingsUtility.sh
    var columns: [String] {
        switch self {
        case .bundleIDLookup:
            ["App Name", "Platform", "Bundle ID", "App Store ID", "Developer", "Version", "Minimum OS", "App Store URL", "External Version ID"]
        case .localMacApps:
            ["App Name", "App Path", "Executable Path", "Bundle ID", "Version", "Composed Identifier", "Architecture", "CDHash", "TeamID", "SigningID", "Designated Requirement", "PathPrefix (suggested)", "SigningState", "Signature Verification"]
        }
    }

    /// File name prefix, e.g. `BundleID-Lookup_2026-10-23_07-15-00.csv`.
    var filePrefix: String {
        switch self {
        case .bundleIDLookup: "BundleID-Lookup"
        case .localMacApps: "Local-Mac-Apps"
        }
    }

    var title: String {
        switch self {
        case .bundleIDLookup: "BundleID-Lookup (App Store and Apple apps)"
        case .localMacApps: "Local-Mac-Apps (signing details)"
        }
    }

    /// A file name in App Settings Utility's `<prefix>_YYYY-MM-DD_HH-MM-SS.csv` form.
    func suggestedFileName(date: Date = Date()) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
        return "\(filePrefix)_\(date.formatted(style)).csv"
    }
}

/// A row of a BundleID-Lookup CSV.
nonisolated struct BundleIDLookupRow: Hashable, Sendable {
    var fields: [CSVField]

    var name: String? { fields[0].value }
    var platforms: [String] { fields[1].value?.components(separatedBy: ", ") ?? [] }
    var bundleID: String? { fields[2].value }
    var appStoreID: String? { fields[3].value }

    init(fields: [CSVField]) {
        self.fields = fields
    }

    /// As App Settings Utility writes a search result: the App Store ID as a number,
    /// a missing external version ID as an empty string.
    init(app: AppStoreApp, detail: AppStoreDetail?) {
        fields = [
            .text(app.name),
            .text(app.platforms.joined(separator: ", ")),
            .optionalText(app.bundleID),
            .bare(String(app.appStoreID)),
            .optionalText(app.developer),
            .optionalText(detail?.version ?? app.version),
            .optionalText(app.minimumOS),
            .optionalText(app.appStoreURL),
            detail?.externalVersionID.map(CSVField.bare) ?? .text(""),
        ]
    }

    /// As App Settings Utility writes an entry of its embedded Apple app list.
    init(appleApp: AppleBuiltInApps.App) {
        fields = [
            .text(appleApp.name), .text("iPhone / iPad (Apple reference)"), .text(appleApp.bundleId),
            .null, .text("Apple"), .null, .null, .null, .text(""),
        ]
    }
}

/// A row of a Local-Mac-Apps CSV: one per architecture slice.
nonisolated struct LocalMacAppRow: Hashable, Sendable {
    var fields: [CSVField]

    var name: String? { fields[0].value }
    var appPath: String? { fields[1].value }
    var bundleID: String? { fields[3].value }
    var composedIdentifier: String? { fields[5].value }
    var architecture: String? { fields[6].value }
    var cdHash: String? { fields[7].value }
    var teamID: String? { fields[8].value }
    var signingID: String? { fields[9].value }
    var pathPrefix: String? { fields[11].value }
    var signingState: String? { fields[12].value }

    init(fields: [CSVField]) {
        self.fields = fields
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — inspect_local_app and export_local_csv in appSettingsUtility.sh
    /// One row per slice. Every value is a string; missing values are empty strings.
    static func rows(for binary: InspectedBinary) -> [LocalMacAppRow] {
        binary.slices.map { slice in
            LocalMacAppRow(fields: [
                binary.name, binary.path, binary.executablePath ?? "", binary.bundleID ?? "", binary.version ?? "",
                binary.composedIdentifier ?? "", slice.architecture, slice.cdHash ?? "", slice.teamID ?? "",
                slice.signingID ?? "", binary.designatedRequirement ?? "", binary.suggestedPathPrefix,
                slice.signingState.rawValue, binary.verification.csvValue,
            ].map(CSVField.text))
        }
    }

    /// The signing values this row describes, for building binary rules.
    var slice: SliceSignature {
        SliceSignature(
            architecture: architecture ?? "Unknown",
            isAppleSilicon: architecture?.hasPrefix("arm") ?? false,
            cdHash: cdHash,
            teamID: teamID,
            signingID: signingID,
            designatedRequirement: fields[10].value,
            signingState: signingState.flatMap(DetectedSigningState.init(rawValue:)) ?? .unknown
        )
    }
}

/// A parsed CSV file of either layout.
nonisolated enum CSVDocument: Hashable, Sendable {
    case bundleIDLookup([BundleIDLookupRow])
    case localMacApps([LocalMacAppRow])

    var format: CSVFormat {
        switch self {
        case .bundleIDLookup: .bundleIDLookup
        case .localMacApps: .localMacApps
        }
    }

    var rowCount: Int {
        switch self {
        case .bundleIDLookup(let rows): rows.count
        case .localMacApps(let rows): rows.count
        }
    }

    var fieldRows: [[CSVField]] {
        switch self {
        case .bundleIDLookup(let rows): rows.map(\.fields)
        case .localMacApps(let rows): rows.map(\.fields)
        }
    }
}

import Foundation

/// The embedded Apple app reference list (Resources/AppleBuiltInApps.json).
nonisolated struct AppleBuiltInApps: Decodable, Sendable {
    struct App: Decodable, Hashable, Sendable, Identifiable {
        let name: String
        let bundleId: String
        let builtIn: Bool

        var id: String { bundleId }
    }

    let source: String
    let appleSource: String
    let verified: String
    let notes: [String]
    let apps: [App]

    var builtInApps: [App] { apps.filter(\.builtIn) }

    /// The verification date as recorded, e.g. "11 September 2026".
    var verifiedDisplay: String {
        // Parsed and formatted in GMT so the day never shifts with the local time zone.
        let parse = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
        guard let date = try? parse.parse(verified) else { return verified }
        var style = Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "en_GB"))
        style.timeZone = .gmt
        return date.formatted(style)
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — apple_preinstalled_data and apple_builtin_data in appSettingsUtility.sh
    /// Loads the list bundled with the app.
    static func load(bundle: Bundle = .main) throws -> AppleBuiltInApps {
        guard let url = bundle.url(forResource: "AppleBuiltInApps", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AppleBuiltInApps.self, from: Data(contentsOf: url))
    }
}

import Foundation

/// The App Store search platforms. Labels match App Settings Utility's CSV output.
nonisolated enum AppStorePlatform: String, CaseIterable, Identifiable, Hashable, Sendable {
    case iPhone
    case iPad
    case mac

    var id: String { rawValue }

    // Ported from cantscript/AppSettingsUtility (MIT) — platform_entity in appSettingsUtility.sh
    var entity: String {
        switch self {
        case .iPhone: "software"
        case .iPad: "iPadSoftware"
        case .mac: "macSoftware"
        }
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — platform_display_name in appSettingsUtility.sh
    var label: String {
        switch self {
        case .iPhone: "iPhone / iOS"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }

    var shortName: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}

/// What to search: one platform, or all three at once.
nonisolated enum AppStoreSearchScope: Hashable, Sendable, Identifiable, CaseIterable {
    case all
    case platform(AppStorePlatform)

    static let allCases: [AppStoreSearchScope] = [.all] + AppStorePlatform.allCases.map(Self.platform)

    var id: String { platforms.map(\.rawValue).joined(separator: "+") }
    var title: String {
        if case .platform(let platform) = self { return platform.shortName }
        return "All"
    }

    var platforms: [AppStorePlatform] {
        if case .platform(let platform) = self { return [platform] }
        return AppStorePlatform.allCases
    }
}

/// One search result. Values the API did not return stay nil and display as
/// "Unavailable"; nothing is filled in.
nonisolated struct AppStoreApp: Identifiable, Hashable, Sendable {
    let appStoreID: Int
    var name: String
    var bundleID: String?
    var developer: String?
    var version: String?
    var minimumOS: String?
    var appStoreURL: String?
    /// Platform labels, e.g. "iPhone / iOS". Merged results carry every platform.
    var platforms: [String]
    var seller: String?
    var formattedPrice: String?
    var ageRating: String?
    var vppDeviceLicensing: Bool?
    var artworkURL: URL?

    var id: Int { appStoreID }

    /// Known platforms in display order (iPhone, iPad, Mac).
    var platformBadges: [AppStorePlatform] {
        AppStorePlatform.allCases.filter { platforms.contains($0.label) }
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — normalise_results in appSettingsUtility.sh
    /// Builds a result from one item of the search response, tagged with `platformLabel`.
    init?(searchResult item: JSONValue, platformLabel: String) {
        guard let id = item["trackId"]?.numberValue?.intValue else { return nil }
        appStoreID = id
        name = item["trackName"]?.stringValue ?? ""
        bundleID = item["bundleId"]?.stringValue
        developer = item["artistName"]?.stringValue
        version = item["version"]?.stringValue
        minimumOS = item["minimumOsVersion"]?.stringValue
        appStoreURL = item["trackViewUrl"]?.stringValue
        platforms = [platformLabel]
        seller = item["sellerName"]?.stringValue
        formattedPrice = item["formattedPrice"]?.stringValue
        ageRating = item["trackContentRating"]?.stringValue
        vppDeviceLicensing = item["isVppDeviceBasedLicensingEnabled"]?.boolValue
        artworkURL = item["artworkUrl60"]?.stringValue.flatMap(URL.init(string:))
    }

    init(
        appStoreID: Int, name: String, bundleID: String?, developer: String?, version: String?,
        minimumOS: String?, appStoreURL: String?, platforms: [String], seller: String? = nil,
        formattedPrice: String? = nil, ageRating: String? = nil, vppDeviceLicensing: Bool? = nil,
        artworkURL: URL? = nil
    ) {
        self.appStoreID = appStoreID
        self.name = name
        self.bundleID = bundleID
        self.developer = developer
        self.version = version
        self.minimumOS = minimumOS
        self.appStoreURL = appStoreURL
        self.platforms = platforms
        self.seller = seller
        self.formattedPrice = formattedPrice
        self.ageRating = ageRating
        self.vppDeviceLicensing = vppDeviceLicensing
        self.artworkURL = artworkURL
    }
}

/// The undocumented MDM lockup detail for one app. Every field is optional.
nonisolated struct AppStoreDetail: Hashable, Sendable {
    var seller: String?
    var version: String?
    var externalVersionID: String?
    var minimumOS: String?
    var deviceFamilies: [String]
    var price: String?
    var ageRating: String?
    var vppDeviceLicensing: Bool?

    // Ported from cantscript/AppSettingsUtility (MIT) — load_app_details in appSettingsUtility.sh
    /// Reads `results[<id>]`. Returns nil unless it is an object with a bundleId.
    init?(lookupResponse json: JSONValue, appStoreID: Int) {
        guard let detail = json["results"]?[String(appStoreID)], detail.objectValue != nil,
              detail["bundleId"]?.stringValue != nil else { return nil }
        // The first offer that has both a display version and an external version ID.
        let offer = detail["offers"]?.arrayValue?.first {
            $0["version"]?["display"]?.stringValue != nil && $0["version"]?["externalId"].map(Self.text) != nil
        }
        seller = detail["softwareInfo"]?["seller"]?.stringValue
        version = offer?["version"]?["display"]?.stringValue
        externalVersionID = offer?["version"]?["externalId"].flatMap(Self.text)
        minimumOS = detail["minimumOSVersion"]?.stringValue
        deviceFamilies = detail["deviceFamilies"]?.arrayValue?.compactMap(\.stringValue) ?? []
        price = detail["offers"]?[0]?["priceFormatted"]?.stringValue
        ageRating = detail["contentRatingsBySystem"]?["appsApple"]?["name"]?.stringValue
        vppDeviceLicensing = detail["isVppDeviceBasedLicensingEnabled"]?.boolValue
    }

    private static func text(_ value: JSONValue) -> String? {
        value.stringValue ?? value.numberValue?.literal
    }
}

/// Talks only to Apple's public App Store endpoints. Uses its own ephemeral session
/// and never sends Jamf data or credentials.
nonisolated struct AppStoreClient: Sendable {
    struct SearchResult: Sendable {
        var apps: [AppStoreApp]
        /// Platforms whose search failed when searching all three.
        var failedPlatforms: [AppStorePlatform]
    }

    struct LookupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let resultLimit = 50
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// Searches one platform, or all three concurrently and merged by App Store ID.
    /// Fails only when every platform's search fails.
    func search(term: String, scope: AppStoreSearchScope, country: String) async throws -> SearchResult {
        let platforms = scope.platforms
        let outcomes = await withTaskGroup(of: (Int, Result<[AppStoreApp], Error>).self) { group in
            for (index, platform) in platforms.enumerated() {
                group.addTask {
                    do { return (index, .success(try await searchEntity(term: term, platform: platform, country: country))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var outcomes: [(Int, Result<[AppStoreApp], Error>)] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var lists: [[AppStoreApp]] = []
        var failed: [AppStorePlatform] = []
        var firstError: Error?
        for (platform, outcome) in zip(platforms, outcomes) {
            switch outcome {
            case .success(let apps): lists.append(apps)
            case .failure(let error):
                failed.append(platform)
                firstError = firstError ?? error
            }
        }
        if lists.isEmpty, let firstError { throw firstError }
        let apps = platforms.count == 1 ? (lists.first ?? []) : Self.merge(lists)
        return SearchResult(apps: apps, failedPlatforms: failed)
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — search_entity in appSettingsUtility.sh
    func searchEntity(term: String, platform: AppStorePlatform, country: String) async throws -> [AppStoreApp] {
        let url = try Self.searchURL(term: term, platform: platform, country: country)
        let json = try await getJSON(url)
        guard let results = json["results"]?.arrayValue else {
            throw LookupError(message: "The App Store search response has no results.")
        }
        return results.compactMap { AppStoreApp(searchResult: $0, platformLabel: platform.label) }
    }

    /// Fetches the undocumented detail lookup. Throws when it is unavailable; callers
    /// show "Details unavailable" and never block on it.
    func detail(appStoreID: Int, country: String) async throws -> AppStoreDetail {
        let url = try Self.detailURL(appStoreID: appStoreID, country: country)
        let json = try await getJSON(url)
        guard let detail = AppStoreDetail(lookupResponse: json, appStoreID: appStoreID) else {
            throw LookupError(message: "The detail response did not contain this app.")
        }
        return detail
    }

    // MARK: Pure helpers

    // Ported from cantscript/AppSettingsUtility (MIT) — merge_results in appSettingsUtility.sh
    /// One record per App Store ID: the first occurrence's fields, with the union of
    /// every occurrence's platform labels (sorted as jq's `unique` sorts them).
    /// Records keep the order in which their ID first appeared.
    static func merge(_ lists: [[AppStoreApp]]) -> [AppStoreApp] {
        var order: [Int] = []
        var merged: [Int: AppStoreApp] = [:]
        for app in lists.joined() {
            if var existing = merged[app.appStoreID] {
                existing.platforms = Array(Set(existing.platforms + app.platforms)).sorted(by: codepointOrder)
                merged[app.appStoreID] = existing
            } else {
                var first = app
                first.platforms = Array(Set(app.platforms)).sorted(by: codepointOrder)
                merged[app.appStoreID] = first
                order.append(app.appStoreID)
            }
        }
        return order.compactMap { merged[$0] }
    }

    static func searchURL(term: String, platform: AppStorePlatform, country: String) throws -> URL {
        try url(
            "https://itunes.apple.com/search",
            query: [("term", term), ("entity", platform.entity), ("country", country), ("limit", String(resultLimit))]
        )
    }

    static func detailURL(appStoreID: Int, country: String) throws -> URL {
        try url(
            "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup",
            query: [("version", "2"), ("id", String(appStoreID)), ("p", "mdm-lockup"), ("caller", "MDM"), ("cc", country)]
        )
    }

    /// Two-letter storefront codes only, lowercased.
    static func normalizedCountry(_ code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters, like jq's
    /// `@uri`, so `+` and `&` in a search term are not misread.
    private static func url(_ base: String, query: [(String, String)]) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        guard let url = URL(string: "\(base)?\(encoded)") else {
            throw LookupError(message: "Could not build the App Store address.")
        }
        return url
    }

    private static func codepointOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    private func getJSON(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError(message: "The App Store answered HTTP \(status).") }
        do {
            return try JSONValue(data: data)
        } catch {
            throw LookupError(message: "The App Store response is not valid JSON.")
        }
    }
}

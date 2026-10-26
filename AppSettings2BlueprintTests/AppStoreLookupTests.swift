import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

/// A search response in the iTunes Search API's shape, with only the fields used.
private func searchResponse(_ items: [(id: Int, name: String, bundle: String?)]) -> String {
    let results = items.map { item in
        let bundle = item.bundle.map { #""bundleId":"\#($0)","# } ?? ""
        return #"{"trackId":\#(item.id),"trackName":"\#(item.name)",\#(bundle)"artistName":"Example Corp","version":"1.2","minimumOsVersion":"17.0","trackViewUrl":"https://apps.apple.com/gb/app/id\#(item.id)","sellerName":"Example Corp Ltd","formattedPrice":"Free","trackContentRating":"4+","isVppDeviceBasedLicensingEnabled":true,"artworkUrl60":"https://is1-ssl.mzstatic.com/a/60.png"}"#
    }
    return #"{"resultCount":\#(items.count),"results":[\#(results.joined(separator: ","))]}"#
}

@Suite("App Store merge and parsing")
struct AppStoreParsingTests {
    private func app(_ id: Int, _ platform: AppStorePlatform, name: String = "App") -> AppStoreApp {
        AppStoreApp(appStoreID: id, name: name, bundleID: "com.example.\(id)", developer: "Example",
                    version: nil, minimumOS: nil, appStoreURL: nil, platforms: [platform.label])
    }

    @Test func duplicateTrackIDAcrossPlatformsBecomesOneRecordWithBothLabels() {
        let merged = AppStoreClient.merge([
            [app(1, .iPhone, name: "First"), app(2, .iPhone)],
            [app(1, .iPad, name: "Second"), app(3, .iPad)],
            [app(1, .mac, name: "Third")],
        ])
        #expect(merged.map(\.appStoreID) == [1, 2, 3])
        let first = merged[0]
        // The first occurrence's fields win; every platform label is kept.
        #expect(first.name == "First")
        #expect(Set(first.platforms) == ["iPhone / iOS", "iPad", "Mac"])
        // jq `unique` order (codepoints), as App Settings Utility writes it to CSV.
        #expect(first.platforms == ["Mac", "iPad", "iPhone / iOS"])
        #expect(first.platformBadges == [.iPhone, .iPad, .mac])
        #expect(merged[1].platforms == ["iPhone / iOS"])
    }

    @Test func mergeDropsDuplicatesWithinOnePlatform() {
        let merged = AppStoreClient.merge([[app(5, .iPhone), app(5, .iPhone)]])
        #expect(merged.count == 1)
        #expect(merged[0].platforms == ["iPhone / iOS"])
    }

    @Test func normalisesSearchResultAndLeavesMissingValuesNil() throws {
        let json = try LosslessJSON(string: searchResponse([(10, "Ten", "com.example.ten"), (11, "Eleven", nil)]))
        let apps = try #require(json["results"]?.arrayValue).compactMap { AppStoreApp(searchResult: $0, platformLabel: "iPad") }
        #expect(apps.count == 2)
        #expect(apps[0].bundleID == "com.example.ten")
        #expect(apps[0].developer == "Example Corp")
        #expect(apps[0].seller == "Example Corp Ltd")
        #expect(apps[0].vppDeviceLicensing == true)
        #expect(apps[0].platforms == ["iPad"])
        #expect(apps[1].bundleID == nil)
        // A result without a trackId is not an app record.
        #expect(AppStoreApp(searchResult: try LosslessJSON(string: #"{"trackName":"x"}"#), platformLabel: "Mac") == nil)
    }

    @Test func parsesDetailLookup() throws {
        let body = #"{"results":{"951937596":{"bundleId":"com.microsoft.Office.Outlook","softwareInfo":{"seller":"Microsoft Corporation"},"minimumOSVersion":"26.0","deviceFamilies":["watch","iphone","ipad"],"isVppDeviceBasedLicensingEnabled":true,"contentRatingsBySystem":{"appsApple":{"name":"4+"}},"offers":[{"priceFormatted":"0,00 €","version":{"display":"5.2641.0","externalId":893334590}}]}}}"#
        let detail = try #require(AppStoreDetail(lookupResponse: try LosslessJSON(string: body), appStoreID: 951937596))
        #expect(detail.seller == "Microsoft Corporation")
        #expect(detail.version == "5.2641.0")
        #expect(detail.externalVersionID == "893334590")
        #expect(detail.minimumOS == "26.0")
        #expect(detail.deviceFamilies == ["watch", "iphone", "ipad"])
        #expect(detail.price == "0,00 €")
        #expect(detail.ageRating == "4+")
        #expect(detail.vppDeviceLicensing == true)
    }

    @Test func detailForAnotherAppOrWithoutBundleIDIsUnavailable() throws {
        let other = try LosslessJSON(string: #"{"results":{"1":{"bundleId":"a"}}}"#)
        let noBundle = try LosslessJSON(string: #"{"results":{"2":{"name":"x"}}}"#)
        #expect(AppStoreDetail(lookupResponse: other, appStoreID: 2) == nil)
        #expect(AppStoreDetail(lookupResponse: noBundle, appStoreID: 2) == nil)
    }

    @Test func buildsSearchURLsLikeAppSettingsUtility() throws {
        let url = try AppStoreClient.searchURL(term: "c++ & notes", platform: .iPad, country: "gb")
        #expect(url.absoluteString == "https://itunes.apple.com/search?term=c%2B%2B%20%26%20notes&entity=iPadSoftware&country=gb&limit=50")
        #expect(try AppStoreClient.searchURL(term: "x", platform: .iPhone, country: "us").absoluteString.contains("entity=software"))
        #expect(try AppStoreClient.searchURL(term: "x", platform: .mac, country: "us").absoluteString.contains("entity=macSoftware"))
        let detail = try AppStoreClient.detailURL(appStoreID: 42, country: "be")
        #expect(detail.absoluteString == "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup?version=2&id=42&p=mdm-lockup&caller=MDM&cc=be")
    }

    @Test(arguments: [("GB", "gb"), (" us ", "us"), ("usa", nil), ("1a", nil), ("", nil), ("é1", nil)] as [(String, String?)])
    func normalisesStorefrontCodes(input: String, expected: String?) {
        #expect(AppStoreClient.normalizedCountry(input) == expected)
    }
}

extension MockNetworkTests {
    @Suite("App Store client")
    struct AppStoreClientTests {
        private let client = AppStoreClient(session: MockURLProtocol.makeSession())

        @Test func allSearchesThreePlatformsAndMerges() async throws {
            MockURLProtocol.install { request in
                switch request.queryValue("entity") {
                case "software": return .json(200, searchResponse([(1, "Shared", "com.example.shared"), (2, "Phone", "com.example.phone")]))
                case "iPadSoftware": return .json(200, searchResponse([(1, "Shared", "com.example.shared")]))
                case "macSoftware": return .json(200, searchResponse([(3, "Mac", "com.example.mac")]))
                default: return .json(404, "{}")
                }
            }
            let result = try await client.search(term: "shared", scope: .all, country: "gb")
            #expect(result.failedPlatforms.isEmpty)
            #expect(result.apps.map(\.appStoreID) == [1, 2, 3])
            #expect(result.apps[0].platformBadges == [.iPhone, .iPad])

            let requests = MockURLProtocol.requests
            #expect(Set(requests.compactMap { $0.queryValue("entity") }) == ["software", "iPadSoftware", "macSoftware"])
            let allMatch1 = requests.allSatisfy { $0.url.host() == "itunes.apple.com" && $0.queryValue("country") == "gb" }
            #expect(allMatch1)
            // Lookups never carry Jamf headers or credentials.
            let allMatch2 = requests.allSatisfy { $0.header("Authorization") == nil && $0.header("X-Environment-Id") == nil }
            #expect(allMatch2)
        }

        @Test func singlePlatformIsNotMerged() async throws {
            MockURLProtocol.install { _ in .json(200, searchResponse([(7, "Seven", "com.example.seven")])) }
            let result = try await client.search(term: "seven", scope: .platform(.mac), country: "us")
            #expect(MockURLProtocol.requests.count == 1)
            #expect(result.apps.first?.platforms == ["Mac"])
        }

        @Test func partialFailureKeepsOtherPlatforms() async throws {
            MockURLProtocol.install { request in
                request.queryValue("entity") == "iPadSoftware"
                    ? .json(503, "{}")
                    : .json(200, searchResponse([(4, "Four", "com.example.four")]))
            }
            let result = try await client.search(term: "four", scope: .all, country: "gb")
            #expect(result.failedPlatforms == [.iPad])
            #expect(result.apps.count == 1)
        }

        @Test func totalFailureThrows() async {
            MockURLProtocol.install { _ in .json(500, "{}") }
            await #expect(throws: AppStoreClient.LookupError.self) {
                try await client.search(term: "x", scope: .all, country: "gb")
            }
        }

        @Test @MainActor func lookupsAreInTheActivityLog() async throws {
            let log = ActivityLog()
            MockURLProtocol.install { _ in .json(200, searchResponse([(7, "Seven", "com.example.seven")])) }
            let client = AppStoreClient(session: MockURLProtocol.makeSession(), log: log)
            _ = try await client.search(term: "seven", scope: .platform(.mac), country: "us")
            let entry = try #require(log.entries.first)
            #expect(log.entries.count == 1)
            #expect(entry.category == "App Store")
            #expect(entry.status == 200)
            #expect(entry.detail.hasPrefix("/search"))
            // A success's body is not recorded (JTKit's default bodies rule).
            #expect(entry.request?.responseBody == nil)
        }

        @Test func failedDetailThrowsInsteadOfReturningInventedValues() async {
            MockURLProtocol.install { _ in .json(200, #"{"results":{}}"#) }
            await #expect(throws: AppStoreClient.LookupError.self) {
                try await client.detail(appStoreID: 99, country: "gb")
            }
            #expect(MockURLProtocol.requests.first?.url.host() == "uclient-api.itunes.apple.com")
        }
    }
}

@Suite("Apple built-in apps")
struct AppleBuiltInAppsTests {
    @Test func bundledListMatchesAppSettingsUtility() throws {
        let list = try AppleBuiltInApps.load()
        #expect(list.apps.count == 75)
        #expect(list.builtInApps.count == 53)
        #expect(Set(list.apps.map(\.bundleId)).count == 75)
        #expect(list.source == "cantscript/AppSettingsUtility (MIT)")
        #expect(list.appleSource == "https://support.apple.com/en-gb/guide/deployment/depece748c41/web")
        #expect(list.verified == "2026-09-11")
        #expect(list.verifiedDisplay == "11 September 2026")
        #expect(list.apps.first { $0.name == "Safari" }?.bundleId == "com.apple.mobilesafari")
        #expect(list.apps.first { $0.name == "App Store Connect" }?.builtIn == false)
    }
}

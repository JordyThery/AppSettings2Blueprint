import Foundation
import Observation

/// State for Lookup → App Store: search, results, local filter and on-demand details.
@Observable
final class AppStoreModel {
    enum SearchState: Equatable {
        case idle
        case searching
        case finished(count: Int, failedPlatforms: [AppStorePlatform])
        case failed(String)
    }

    enum DetailState: Equatable {
        case loading
        case loaded(AppStoreDetail)
        case unavailable(String)
    }

    // Ported from cantscript/AppSettingsUtility (MIT) — change_store in appSettingsUtility.sh
    /// App Settings Utility's storefronts, in its menu order.
    static let presetStorefronts: [(code: String, name: String)] = [
        ("gb", "United Kingdom"), ("us", "United States"), ("ca", "Canada"),
        ("au", "Australia"), ("de", "Germany"), ("fr", "France"),
    ]
    static let storefrontKey = "appStoreStorefront"

    var term = ""
    var scope: AppStoreSearchScope = .all
    /// Lowercase two-letter code. Defaults to the system region.
    var storefront: String {
        didSet { UserDefaults.standard.set(storefront, forKey: Self.storefrontKey) }
    }
    var developerFilter = ""
    var selection: Set<AppStoreApp.ID> = []

    private(set) var results: [AppStoreApp] = []
    private(set) var searchState: SearchState = .idle
    /// The storefront the current results came from.
    private(set) var resultsStorefront: String?
    /// Keyed by "<storefront>:<id>", like App Settings Utility's cache.
    private(set) var details: [String: DetailState] = [:]

    @ObservationIgnored private let client: AppStoreClient
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(client: AppStoreClient = AppStoreClient(), defaults: UserDefaults = .standard) {
        self.client = client
        let stored = defaults.string(forKey: Self.storefrontKey).flatMap(AppStoreClient.normalizedCountry)
        let region = Locale.current.region.flatMap { AppStoreClient.normalizedCountry($0.identifier) }
        storefront = stored ?? region ?? "gb"
    }

    var canSearch: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchState != .searching
    }

    var visibleResults: [AppStoreApp] {
        let filter = developerFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return results }
        return results.filter {
            $0.developer?.localizedCaseInsensitiveContains(filter) == true
                || $0.seller?.localizedCaseInsensitiveContains(filter) == true
        }
    }

    var selectedApps: [AppStoreApp] { results.filter { selection.contains($0.id) } }

    func search() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let scope = scope
        let storefront = storefront
        searchTask?.cancel()
        searchState = .searching
        selection = []
        searchTask = Task {
            do {
                let result = try await client.search(term: term, scope: scope, country: storefront)
                guard !Task.isCancelled else { return }
                results = result.apps
                resultsStorefront = storefront
                searchState = .finished(count: result.apps.count, failedPlatforms: result.failedPlatforms)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    func detailState(for app: AppStoreApp) -> DetailState? {
        details[detailKey(app.appStoreID)]
    }

    /// Fetches the undocumented detail lookup, only when asked. Failure never blocks anything.
    func loadDetail(for app: AppStoreApp) {
        let key = detailKey(app.appStoreID)
        if case .loaded = details[key] { return }
        if details[key] == .loading { return }
        details[key] = .loading
        let country = resultsStorefront ?? storefront
        Task {
            do {
                details[key] = .loaded(try await client.detail(appStoreID: app.appStoreID, country: country))
            } catch {
                details[key] = .unavailable(error.localizedDescription)
            }
        }
    }

    private func detailKey(_ id: Int) -> String { "\(resultsStorefront ?? storefront):\(id)" }
}

import Foundation
import Observation
import os

/// App-wide state: the active connection, the Blueprint list, fetched details and
/// the request log.
@Observable
final class AppModel {
    enum ListState: Equatable {
        case idle
        case listing
        case finished(Date)
        case failed(String)
    }

    let profileStore = ProfileStore()
    let requestLog = RequestLog()
    let updates: UpdateChecker
    let localApps = LocalAppsModel()
    let appStore = AppStoreModel()
    let ruleSet = RuleSetDocument()
    let builtInApps: Result<AppleBuiltInApps, Error> = Result { try AppleBuiltInApps.load() }

    private(set) var overviews: [BlueprintOverview] = []
    private(set) var details: [String: BlueprintDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var loadingDetailIDs: Set<String> = []
    private(set) var listState: ListState = .idle

    var searchText = ""
    var selectedBlueprintID: String? {
        didSet {
            if let selectedBlueprintID, details[selectedBlueprintID] == nil { loadDetail(id: selectedBlueprintID) }
        }
    }

    private var client: PlatformAPIClient?
    private var listTask: Task<Void, Never>?

    init() {
        let logger = Logger(subsystem: "be.jordythery.appsettings2blueprint", category: "updates")
        updates = UpdateChecker(activity: { logger.info("\($0, privacy: .public)") })
    }

    var isListing: Bool { listState == .listing }

    // MARK: Connection

    /// Returns a service for the selected profile, rebuilding the client when credentials change.
    func currentService() throws -> BlueprintService {
        guard let profile = profileStore.selectedProfile,
              let credentials = profileStore.credentials(for: profile) else {
            throw APIError.missingCredentials
        }
        if let client, client.credentials == credentials {
            return BlueprintService(client: client)
        }
        let newClient = makeClient(credentials: credentials)
        client = newClient
        return BlueprintService(client: newClient)
    }

    func makeClient(credentials: PlatformCredentials) -> PlatformAPIClient {
        let log = requestLog
        return PlatformAPIClient(credentials: credentials) { entry in
            log.append(entry)
        }
    }

    /// Called when the user switches profile: clears everything loaded from the old tenant.
    func connectionDidChange() {
        listTask?.cancel()
        client = nil
        overviews = []
        details = [:]
        detailErrors = [:]
        loadingDetailIDs = []
        selectedBlueprintID = nil
        listState = .idle
    }

    // MARK: Blueprints

    /// Lists every Blueprint (overview fields only; the list has no steps).
    func refresh() {
        listTask?.cancel()
        listTask = Task {
            let service: BlueprintService
            do {
                service = try currentService()
            } catch {
                listState = .failed(error.localizedDescription)
                return
            }
            listState = .listing
            do {
                let list = try await service.listAll()
                guard !Task.isCancelled else { return }
                overviews = list
                let ids = Set(list.map(\.id))
                details = details.filter { ids.contains($0.key) }
                detailErrors = [:]
                listState = .finished(Date())
            } catch is CancellationError {
                return
            } catch {
                listState = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches GET /blueprints/v1/blueprints/{id}, replacing any cached copy.
    func loadDetail(id: String) {
        guard !loadingDetailIDs.contains(id) else { return }
        loadingDetailIDs.insert(id)
        detailErrors[id] = nil
        Task {
            defer { loadingDetailIDs.remove(id) }
            do {
                store(try await currentService().detail(id: id))
            } catch {
                detailErrors[id] = error.localizedDescription
            }
        }
    }

    /// Fetches one Blueprint by ID and selects it, even if it is not in the list yet.
    func fetchBlueprint(id: String) async throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let detail = try await currentService().detail(id: trimmed)
        store(detail)
        selectedBlueprintID = detail.id
    }

    private func store(_ detail: BlueprintDetail) {
        details[detail.id] = detail
        detailErrors[detail.id] = nil
        if let index = overviews.firstIndex(where: { $0.id == detail.id }) {
            overviews[index] = detail.overview
        } else {
            overviews.insert(detail.overview, at: 0)
        }
    }

    var visibleOverviews: [BlueprintOverview] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return overviews }
        return overviews.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description?.localizedCaseInsensitiveContains(query) == true
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}

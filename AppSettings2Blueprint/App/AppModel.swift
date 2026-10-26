import Foundation
import JTKit
import Observation
import os

/// App-wide state: the active connection, the Blueprint list, fetched details and
/// JTKit's activity log.
@Observable
final class AppModel {
    enum ListState: Equatable {
        case idle
        case listing
        case finished(Date)
        case failed(String)
    }

    let profileStore = ProfileStore()
    /// JTKit's activity log (Window › Activity Log, ⇧⌘L), filled by the Jamf
    /// client and the App Store lookups.
    let activityLog: ActivityLog
    let updates: UpdateChecker
    let localApps = LocalAppsModel()
    let appStore: AppStoreModel
    let ruleSet = RuleSetDocument()
    let builtInApps: Result<AppleBuiltInApps, Error> = Result { try AppleBuiltInApps.load() }

    private(set) var overviews: [JamfPlatform.BlueprintOverview] = []
    private(set) var details: [String: JamfPlatform.BlueprintDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var loadingDetailIDs: Set<String> = []
    private(set) var listState: ListState = .idle

    /// Blueprints that answered 409 DIVISION_PATCH_NOT_ALLOWED this session.
    var readOnlyBlueprintIDs: Set<String> = []
    private(set) var deviceGroups: [JamfPlatform.DeviceGroup] = []
    private(set) var deviceGroupsError: String?
    private(set) var isLoadingDeviceGroups = false
    /// True when the connection's environment has no platform device groups: the
    /// Device Groups API answers 404 TENANT_NOT_FOUND, which is what a Jamf School
    /// environment returns. Blueprints can still be written and deployed, but
    /// scope cannot be chosen in the app.
    private(set) var isJamfSchool = false

    var searchText = ""
    var selectedBlueprintID: String? {
        didSet {
            if let selectedBlueprintID, details[selectedBlueprintID] == nil { loadDetail(id: selectedBlueprintID) }
        }
    }

    /// JTKit's client for the selected profile, kept while its credentials stay the same.
    private var client: (credentials: PlatformCredentials, client: JamfPlatform.Client)?
    private var listTask: Task<Void, Never>?
    /// Incremented on every profile switch. Async work compares it before storing
    /// results, so a load started against the old tenant cannot repopulate the new one.
    @ObservationIgnored private var connectionGeneration = 0

    init() {
        let log = ActivityLog()
        activityLog = log
        appStore = AppStoreModel(client: AppStoreClient(log: log))
        let logger = Logger(subsystem: "be.jordythery.appsettings2blueprint", category: "updates")
        updates = UpdateChecker(
            configuration: UpdateConfiguration(owner: "JordyThery", repository: "AppSettings2Blueprint", appName: "AppSettings2Blueprint"),
            activity: { logger.info("\($0, privacy: .public)") }
        )
    }

    var isListing: Bool { listState == .listing }

    // MARK: Connection

    /// The client for the selected profile, rebuilt when its credentials change.
    func currentClient() throws -> JamfPlatform.Client {
        guard let profile = profileStore.selectedProfile,
              let credentials = profileStore.credentials(for: profile) else {
            throw APIError.missingCredentials
        }
        if let client, client.credentials == credentials {
            return client.client
        }
        let newClient = try makeClient(credentials: credentials)
        client = (credentials, newClient)
        return newClient
    }

    /// The Blueprints API for the selected profile.
    func currentService() throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try currentClient())
    }

    func makeClient(credentials: PlatformCredentials) throws -> JamfPlatform.Client {
        try PlatformAPIClient.make(credentials: credentials, log: activityLog)
    }

    /// Called when the user switches profile: clears everything loaded from the old tenant.
    func connectionDidChange() {
        connectionGeneration += 1
        listTask?.cancel()
        client = nil
        overviews = []
        details = [:]
        detailErrors = [:]
        loadingDetailIDs = []
        selectedBlueprintID = nil
        listState = .idle
        readOnlyBlueprintIDs = []
        deviceGroups = []
        deviceGroupsError = nil
        isJamfSchool = false
    }

    // MARK: Device groups

    func loadDeviceGroups() {
        guard !isLoadingDeviceGroups else { return }
        isLoadingDeviceGroups = true
        deviceGroupsError = nil
        Task {
            defer { isLoadingDeviceGroups = false }
            let generation = connectionGeneration
            do {
                let groups = try await currentClient().deviceGroups()
                guard generation == connectionGeneration else { return }
                deviceGroups = groups
                isJamfSchool = false
            } catch let error as JamfPlatformError where error.hasCode(.tenantNotFound) {
                guard generation == connectionGeneration else { return }
                isJamfSchool = true
            } catch {
                guard generation == connectionGeneration else { return }
                deviceGroupsError = error.localizedDescription
            }
        }
    }

    func groupName(_ id: String) -> String {
        if let name = deviceGroups.first(where: { $0.id == id })?.name { return name }
        return isJamfSchool ? "Group \(id)" : id
    }

    // MARK: Blueprints

    /// Whether the blueprint may be written: not division-locked and not refused before.
    func isReadOnly(_ detail: JamfPlatform.BlueprintDetail) -> Bool {
        detail.isDivisionLocked || readOnlyBlueprintIDs.contains(detail.id)
    }

    /// Fetches every listed blueprint's detail (five at a time) that is not loaded
    /// yet, so App Settings in other blueprints can be found.
    func loadMissingDetails() async {
        guard let service = try? currentService() else { return }
        let generation = connectionGeneration
        let missing = overviews.map(\.id).filter { details[$0] == nil }
        await withTaskGroup(of: JamfPlatform.BlueprintDetail?.self) { group in
            var pending = missing[...]
            func enqueue() {
                guard let id = pending.popFirst() else { return }
                group.addTask { try? await service.detail(id: id) }
            }
            for _ in 0..<5 { enqueue() }
            for await detail in group {
                guard generation == connectionGeneration else {
                    group.cancelAll()
                    return
                }
                if let detail { store(detail) }
                enqueue()
            }
        }
    }

    /// Records a blueprint fetched elsewhere (writes, read-backs).
    func storeDetail(_ detail: JamfPlatform.BlueprintDetail) {
        store(detail)
    }

    /// Lists every Blueprint (overview fields only; the list has no steps).
    func refresh() {
        listTask?.cancel()
        listTask = Task {
            let service: JamfPlatform.Blueprints
            do {
                service = try currentService()
            } catch {
                listState = .failed(error.localizedDescription)
                return
            }
            listState = .listing
            do {
                let list = try await service.list()
                guard !Task.isCancelled else { return }
                overviews = list
                let ids = Set(list.map(\.id))
                details = details.filter { ids.contains($0.key) }
                detailErrors = [:]
                listState = .finished(Date())
                // Also tells whether this is a Jamf School environment.
                if deviceGroups.isEmpty && !isJamfSchool { loadDeviceGroups() }
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
            let generation = connectionGeneration
            do {
                let detail = try await currentService().detail(id: id)
                guard generation == connectionGeneration else { return }
                store(detail)
            } catch {
                guard generation == connectionGeneration else { return }
                detailErrors[id] = error.localizedDescription
            }
        }
    }

    /// Fetches one Blueprint by ID and selects it, even if it is not in the list yet.
    func fetchBlueprint(id: String) async throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = connectionGeneration
        let detail = try await currentService().detail(id: trimmed)
        guard generation == connectionGeneration else { return }
        store(detail)
        selectedBlueprintID = detail.id
    }

    private func store(_ detail: JamfPlatform.BlueprintDetail) {
        details[detail.id] = detail
        detailErrors[detail.id] = nil
        if let index = overviews.firstIndex(where: { $0.id == detail.id }) {
            overviews[index] = detail.overview
        } else {
            overviews.insert(detail.overview, at: 0)
        }
    }

    var visibleOverviews: [JamfPlatform.BlueprintOverview] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return overviews }
        return overviews.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description?.localizedCaseInsensitiveContains(query) == true
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
}

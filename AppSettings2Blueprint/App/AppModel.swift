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

    let profileStore: ProfileStore
    /// JTKit's demo mode: Contoso's sample tenant, answered inside the app.
    /// Saved under `demoMode`.
    let demo: DemoMode
    /// Demo mode's connection for Settings › Connections: with it, Use This
    /// Connection there leaves demo mode, as the toolbar picker does.
    @ObservationIgnored let demoChoice: DemoConnectionChoice
    /// JTKit's activity log (Window › Activity Log, ⇧⌘L), filled by the Jamf
    /// client and the App Store lookups.
    let activityLog: ActivityLog
    let updates: UpdateChecker
    /// Waits before a retry of the app's own loads (lists, details). Each
    /// sheet has its own (`service(waits:)`), shown there with Stop, so Stop
    /// ends only that sheet's wait. JTKit waits at most 60 s each time.
    let waits = RequestWaits()
    /// Where the app's own settings are saved (sidebar selection, storefront,
    /// scan folders): the real preferences, or a sandbox run's own suite.
    @ObservationIgnored let defaults: UserDefaults
    let localApps: LocalAppsModel
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
    /// Fetch Blueprint by ID…, from the toolbar or the View menu.
    var isShowingFetchByID = false

    /// A menu-bar command for the editor (File menu, Blueprint › Write to
    /// Jamf…). The window shows the editor, which carries it out with its own
    /// confirmations and clears it.
    enum EditorCommand: Equatable {
        case new(RulePlatform), open, save, importCSV, writeToJamf
    }
    var editorCommand: EditorCommand?

    /// A menu-bar command for the selected Blueprint (Blueprint menu); the
    /// window shows Blueprints, whose detail pane carries it out.
    enum BlueprintCommand: Equatable {
        case reload, backups, editScope, deploy
    }
    var blueprintCommand: BlueprintCommand?

    /// The selected Blueprint's detail, when it's loaded.
    var selectedDetail: JamfPlatform.BlueprintDetail? {
        selectedBlueprintID.flatMap { details[$0] }
    }
    var selectedBlueprintID: String? {
        didSet {
            if let selectedBlueprintID, details[selectedBlueprintID] == nil { loadDetail(id: selectedBlueprintID) }
        }
    }

    /// JTKit's client for the selected profile, kept while its credentials stay the same.
    private var client: (credentials: PlatformCredentials, client: JamfPlatform.Client)?
    /// JTKit's client for demo mode, the same for the whole launch.
    @ObservationIgnored private var demoClient: JamfPlatform.Client?
    /// The network for real connections; demo mode has its own.
    @ObservationIgnored let session: URLSession
    private var listTask: Task<Void, Never>?
    /// Incremented on every connection or demo switch. Async work compares it
    /// before storing results, so a load started against the old tenant can’t
    /// repopulate the new one; the write, deploy, scope and restore sheets
    /// compare it before sending and again before storing what came back.
    private(set) var connectionGeneration = 0

    /// What decides the tenant: demo mode, or the connection in use and its
    /// region, Environment ID and client ID. Its name doesn't.
    struct ConnectionKey: Equatable {
        var demo: Bool
        var profileID: UUID?
        var region: JamfRegion?
        var environmentID: String?
        var clientID: String?
    }

    var connectionKey: ConnectionKey {
        let profile = profileStore.selectedProfile
        return ConnectionKey(demo: demo.isOn, profileID: profile?.id, region: profile?.region,
                             environmentID: profile?.environmentID, clientID: profile?.clientID)
    }

    /// The key the loaded data belongs to.
    @ObservationIgnored private var appliedConnectionKey: ConnectionKey?

    static let demoModeKey = "demoMode"

    /// - Parameters:
    ///   - profileStore: the saved connections; in-memory ones for a sandbox run.
    ///   - demo: the app passes its saved demo mode (`forLaunch()`). Previews
    ///     and tests start with it off, and save nothing.
    ///   - session: the network for real connections.
    ///   - defaults: where the app's own settings are saved.
    ///   - backupRoot: where backups go outside demo mode; tests pass a
    ///     temporary folder.
    init(
        profileStore: ProfileStore = ProfileStore(),
        demo: DemoMode? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        backupRoot: URL = BackupStore.rootURL
    ) {
        self.profileStore = profileStore
        self.demo = demo ?? DemoMode(key: Self.demoModeKey, arguments: [DemoMode.launchArgument, "NO"])
        demoChoice = DemoConnectionChoice(mode: self.demo, connections: [.demoJamfPlatform])
        self.session = session
        self.defaults = defaults
        realBackupRoot = backupRoot
        let log = ActivityLog()
        activityLog = log
        localApps = LocalAppsModel(defaults: defaults)
        // A sandbox run (UI tests) makes no public lookups: its App Store client
        // reaches nothing but demo mode's empty network.
        let lookups = self.demo.isSandbox ? DemoNetwork(servers: [:]).session : URLSession(configuration: .ephemeral)
        appStore = AppStoreModel(client: AppStoreClient(session: lookups, log: log), defaults: defaults)
        let logger = Logger(subsystem: "be.jordythery.appsettings2blueprint", category: "updates")
        defer {
            appliedConnectionKey = connectionKey
            watchConnection()
        }
        updates = UpdateChecker(
            configuration: UpdateConfiguration(owner: "JordyThery", repository: "AppSettings2Blueprint", appName: "AppSettings2Blueprint"),
            activity: { logger.info("\($0, privacy: .public)") }
        )
    }

    /// The model for this launch: the saved connections and demo mode, or, for
    /// a sandbox run (`-JTKitSandbox YES`), connections and secrets in memory
    /// and settings in the run's own suite.
    static func forLaunch() -> AppModel {
        let demo = DemoMode(key: demoModeKey)
        guard demo.isSandbox else { return AppModel(demo: demo) }
        let defaults = DemoMode.sandboxDefaults()
        return AppModel(profileStore: ProfileStore(defaults: defaults, secrets: SandboxSecretStore()),
                        demo: demo, defaults: defaults)
    }

    // MARK: Settings

    static let sidebarSelectionKey = "sidebarSelection"

    /// The sidebar row of the last launch; read once when the window opens.
    var savedSidebarSelection: SidebarItem? {
        defaults.string(forKey: Self.sidebarSelectionKey).flatMap(SidebarItem.init(rawValue:))
    }

    func saveSidebarSelection(_ item: SidebarItem?) {
        defaults.set(item?.rawValue, forKey: Self.sidebarSelectionKey)
    }

    var isListing: Bool { listState == .listing }

    // MARK: Connection

    /// Whether Jamf can be reached: a connection is chosen, or demo mode is on.
    var hasActiveConnection: Bool { demo.isOn || profileStore.selectedProfile != nil }

    /// The client for demo mode or the selected profile, rebuilt when its
    /// credentials change. In demo mode no saved connection or Keychain item
    /// is read, and nothing is sent to a tenant.
    func currentClient() throws -> JamfPlatform.Client {
        applyConnectionChange()
        if demo.isOn {
            if let demoClient { return demoClient }
            let source = demo.jamfPlatform()
            let made = try PlatformAPIClient.make(connection: source.connection, secret: source.secret,
                                                  session: source.session, log: activityLog, waits: waits)
            demoClient = made
            return made
        }
        guard let profile = profileStore.selectedProfile else { throw APIError.missingCredentials }
        let credentials = try profileStore.credentials(for: profile)
        if let client, client.credentials == credentials {
            return client.client
        }
        let newClient = try makeClient(credentials: credentials)
        client = (credentials, newClient)
        return newClient
    }

    /// A client of its own for one sheet, whose waits before a retry show
    /// in that sheet (`waits`). Same connection as `currentClient()`.
    func service(waits: RequestWaits) throws -> JamfPlatform.Blueprints {
        applyConnectionChange()
        if demo.isOn {
            let source = demo.jamfPlatform()
            return JamfPlatform.Blueprints(client: try PlatformAPIClient.make(
                connection: source.connection, secret: source.secret, session: source.session,
                log: activityLog, waits: waits))
        }
        guard let profile = profileStore.selectedProfile else { throw APIError.missingCredentials }
        let credentials = try profileStore.credentials(for: profile)
        return JamfPlatform.Blueprints(client: try PlatformAPIClient.make(
            credentials: credentials, session: session, log: activityLog, waits: waits))
    }

    /// The Platform API’s Blueprints for the selected profile.
    func currentService() throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try currentClient())
    }

    /// A client for a real connection, on the real network, also while demo
    /// mode is on (Settings › Connections' Test Connection).
    func makeClient(credentials: PlatformCredentials) throws -> JamfPlatform.Client {
        try PlatformAPIClient.make(credentials: credentials, session: session, log: activityLog, waits: waits)
    }

    // MARK: Backups

    /// Where backups are written and listed: the real folder, or demo mode's
    /// temporary one, so demo writes never reach `Backups/`.
    var backupRoot: URL {
        demo.isOn ? demo.scratchDirectory.appending(path: "Backups", directoryHint: .isDirectory) : realBackupRoot
    }
    @ObservationIgnored private let realBackupRoot: URL

    /// How long backups are kept (Settings › General); forever unless chosen.
    var backupRetention: BackupStore.Retention {
        get {
            access(keyPath: \.backupRetention)
            return BackupStore.Retention(rawValue: defaults.integer(forKey: BackupStore.retentionKey)) ?? .forever
        }
        set {
            withMutation(keyPath: \.backupRetention) {
                defaults.set(newValue.rawValue, forKey: BackupStore.retentionKey)
            }
            BackupStore.prune(newValue, root: backupRoot)
        }
    }

    /// A writer for the current connection that backs up into `backupRoot`,
    /// then removes backups older than the retention allows.
    /// - Parameter waits: the sheet's own waits; nil uses the shared client.
    func makeWriter(waits: RequestWaits? = nil) throws -> BlueprintWriter {
        var writer = BlueprintWriter(service: try waits.map(service(waits:)) ?? currentService())
        let root = backupRoot
        let retention = backupRetention
        writer.backup = { detail in
            let url = try BackupStore.write(detail, root: root)
            BackupStore.prune(retention, root: root)
            return url
        }
        return writer
    }

    /// Applies a switch made anywhere (toolbar picker, Connection menu,
    /// Settings, demo toggle), also while the main window is closed: the
    /// observation fires before the change, and the check runs right after it
    /// on the main actor, before SwiftUI draws again.
    private func watchConnection() {
        withObservationTracking {
            _ = connectionKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyConnectionChange()
                self?.watchConnection()
            }
        }
    }

    /// Clears the old tenant's data when the tenant changed since it was loaded.
    func applyConnectionChange() {
        let key = connectionKey
        guard key != appliedConnectionKey else { return }
        appliedConnectionKey = key
        connectionDidChange()
    }

    /// Clears everything
    /// loaded from the old tenant, including the rule set's link to one of
    /// its Blueprints (that ID means nothing on the new one).
    func connectionDidChange() {
        connectionGeneration += 1
        ruleSet.linkedBlueprint = nil
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
            } catch let error as JamfPlatform.APIError where error.hasCode(.tenantNotFound) {
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

    /// Fetches every listed Blueprint's detail (five at a time) that isn’t loaded
    /// yet, so App Settings in other Blueprints can be found. A failure is kept
    /// in `detailErrors`; that Blueprint is tried again on the next call.
    func loadMissingDetails() async {
        guard let service = try? currentService() else { return }
        let generation = connectionGeneration
        let missing = overviews.map(\.id).filter { details[$0] == nil && !loadingDetailIDs.contains($0) }
        loadingDetailIDs.formUnion(missing)
        defer { if generation == connectionGeneration { loadingDetailIDs.subtract(missing) } }
        for id in missing { detailErrors[id] = nil }
        await withTaskGroup(of: (id: String, detail: JamfPlatform.BlueprintDetail?, error: String?).self) { group in
            var pending = missing[...]
            func enqueue() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    do {
                        return (id, try await service.detail(id: id), nil)
                    } catch {
                        return (id, nil, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<5 { enqueue() }
            for await answer in group {
                guard generation == connectionGeneration else {
                    group.cancelAll()
                    return
                }
                if let detail = answer.detail { store(detail) }
                if let error = answer.error { detailErrors[answer.id] = error }
                enqueue()
            }
        }
    }

    /// Records a Blueprint fetched elsewhere (writes, read-backs).
    func storeDetail(_ detail: JamfPlatform.BlueprintDetail) {
        store(detail)
    }

    /// As `storeDetail(_:)`, only when the connection is still the one the
    /// request went to (`generation`); a result that arrives after a switch
    /// is shown in its sheet only. True when it was stored.
    @discardableResult
    func storeDetail(_ detail: JamfPlatform.BlueprintDetail, generation: Int) -> Bool {
        guard generation == connectionGeneration else { return false }
        store(detail)
        return true
    }

    /// After a write that may have reached Jamf but couldn’t be verified: the
    /// cached copy is out of date, so it is dropped and fetched again (a new
    /// Blueprint is added to the list that way).
    func reloadAfterUncertainWrite(id: String?, generation: Int? = nil) {
        if let generation, generation != connectionGeneration { return }
        if let id {
            details[id] = nil
            loadDetail(id: id)
        } else {
            refresh()
        }
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
                // A Blueprint fetched by ID that the list doesn't return: its
                // detail is gone, so it can't stay selected.
                if let selected = selectedBlueprintID, !ids.contains(selected) { selectedBlueprintID = nil }
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

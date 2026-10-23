import AppKit
import SwiftUI

/// Lookup → App Store: search Apple's App Store for bundle IDs (iOS/iPadOS rules).
struct AppStoreSearchView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.appStore
        VStack(spacing: 0) {
            SearchBar()
                .padding(10)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ResultsTable()
                    Divider()
                    StatusBar()
                }
                .frame(minWidth: 520, maxWidth: .infinity)
                Divider()
                Group {
                    if model.selectedApps.count == 1, let selected = model.selectedApps.first {
                        AppStoreDetailPane(app: selected)
                            .id(selected.id)
                    } else if model.selectedApps.count > 1 {
                        ContentUnavailableView(
                            "\(model.selectedApps.count) Apps Selected",
                            systemImage: "square.stack",
                            description: Text("Right-click to copy their bundle IDs.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No App Selected",
                            systemImage: "bag",
                            description: Text("Search the App Store, then select a result to see its identifiers.")
                        )
                    }
                }
                .frame(width: 340)
            }
        }
    }
}

private struct SearchBar: View {
    @Environment(AppModel.self) private var app
    @State private var otherStorefront = ""

    var body: some View {
        @Bindable var model = app.appStore
        HStack(spacing: 10) {
            TextField("Search the App Store", text: $model.term)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.search() }
                .frame(minWidth: 200)
            Picker("Platform", selection: $model.scope) {
                ForEach(AppStoreSearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("All searches iPhone, iPad and Mac at once and merges the results")
            Picker("Storefront", selection: $model.storefront) {
                ForEach(AppStoreModel.presetStorefronts, id: \.code) { store in
                    Text("\(store.name) (\(store.code.uppercased()))").tag(store.code)
                }
                if !AppStoreModel.presetStorefronts.contains(where: { $0.code == model.storefront }) {
                    Divider()
                    Text(model.storefront.uppercased()).tag(model.storefront)
                }
            }
            .fixedSize()
            .help("App Store storefront (country)")
            TextField("Other", text: $otherStorefront, prompt: Text("cc"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .help("Any two-letter storefront code, e.g. BE or NL. Press Return to use it.")
                .onSubmit {
                    if let code = AppStoreClient.normalizedCountry(otherStorefront) {
                        model.storefront = code
                        otherStorefront = ""
                    }
                }
            Button("Search") { model.search() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSearch)
        }
    }
}

private struct ResultsTable: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.appStore
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                TextField("Filter by developer", text: $model.developerFilter)
                    .textFieldStyle(.plain)
                SelectionActions()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Table(model.visibleResults, selection: $model.selection) {
                TableColumn("Name") { app in
                    HStack(spacing: 6) {
                        AppIcon(url: app.artworkURL)
                        Text(app.name)
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Developer") { app in Text(app.developer ?? "Unavailable") }
                    .width(min: 100, ideal: 150)
                TableColumn("Platforms") { app in PlatformBadges(platforms: app.platformBadges) }
                    .width(min: 140, ideal: 160)
                TableColumn("Bundle ID") { app in
                    Text(app.bundleID ?? "Unavailable")
                        .font(.body.monospaced())
                        .foregroundStyle(app.bundleID == nil ? .tertiary : .primary)
                }
                .width(min: 140, ideal: 220)
                TableColumn("App Store ID") { app in
                    Text(String(app.appStoreID)).font(.body.monospaced())
                }
                .width(min: 100, ideal: 115)
            }
            .contextMenu(forSelectionType: AppStoreApp.ID.self) { ids in
                let apps = model.results.filter { ids.contains($0.id) }
                let bundleIDs = apps.compactMap(\.bundleID)
                Button(bundleIDs.count > 1 ? "Add \(bundleIDs.count) Apps to Rule Set" : "Add to Rule Set") {
                    app.ruleSet.addApps(apps.compactMap { app in app.bundleID.map { ($0, app.name) } })
                }
                .disabled(bundleIDs.isEmpty)
                Button(bundleIDs.count > 1 ? "Copy \(bundleIDs.count) Bundle IDs" : "Copy Bundle ID") {
                    copy(bundleIDs.joined(separator: "\n"))
                }
                .disabled(bundleIDs.isEmpty)
            }
            .overlay {
                if model.searchState == .searching {
                    ProgressView("Searching…")
                } else if case .finished = model.searchState, model.visibleResults.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
    }
}

/// Add-to-rule-set and CSV export for the selected results.
private struct SelectionActions: View {
    @Environment(AppModel.self) private var app
    @State private var errorMessage: String?

    var body: some View {
        let model = app.appStore
        let selected = model.selectedApps
        let withBundleID = selected.filter { $0.bundleID != nil }
        HStack(spacing: 8) {
            Button("Add to Rule Set\(withBundleID.count > 1 ? " (\(withBundleID.count))" : "")", systemImage: "plus.circle") {
                app.ruleSet.addApps(withBundleID.compactMap { app in app.bundleID.map { ($0, app.name) } })
            }
            .disabled(withBundleID.isEmpty)
            .help("Add the selected bundle IDs to the iOS / iPadOS app list; duplicates are skipped")
            Button("Export CSV…", systemImage: "tablecells") {
                let rows = selected.map { app -> BundleIDLookupRow in
                    let detail: AppStoreDetail? = if case .loaded(let detail) = model.detailState(for: app) { detail } else { nil }
                    return BundleIDLookupRow(app: app, detail: detail)
                }
                do { try CSVExport.save(.bundleIDLookup(rows)) } catch { errorMessage = error.localizedDescription }
            }
            .disabled(selected.isEmpty)
            .help("Save the selected results as an App Settings Utility BundleID-Lookup CSV")
        }
        .controlSize(.small)
        .alert("Couldn't Export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.appStore
        HStack(spacing: 6) {
            switch model.searchState {
            case .idle:
                Text("Results come from itunes.apple.com. No Jamf data is sent.")
            case .searching:
                ProgressView().controlSize(.small)
                Text("Searching…")
            case .finished(let count, let failed):
                Text("\(count) result\(count == 1 ? "" : "s") from the \((model.resultsStorefront ?? "").uppercased()) storefront")
                if !failed.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(failed.map(\.shortName).joined(separator: ", ")) search failed; results may be incomplete.")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Search failed: \(message)")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
}

/// Identifiers and on-demand details for one search result.
private struct AppStoreDetailPane: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp

    var body: some View {
        let detailState = model.appStore.detailState(for: app)
        let detail: AppStoreDetail? = if case .loaded(let detail) = detailState { detail } else { nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AppIcon(url: app.artworkURL, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        PlatformBadges(platforms: app.platformBadges)
                    }
                }
                if let bundleID = app.bundleID {
                    Button("Add to Rule Set", systemImage: "plus.circle") {
                        model.ruleSet.addApps([(bundleID, app.name)])
                    }
                }
                CompactValueRow(label: "Bundle ID", value: app.bundleID, copyable: true)
                CompactValueRow(label: "App Store ID", value: String(app.appStoreID), copyable: true)
                CompactValueRow(label: "Developer", value: app.developer)
                if let url = app.appStoreURL.flatMap(URL.init(string:)) {
                    Link("View in App Store", destination: url)
                        .font(.callout)
                }

                Divider()

                HStack {
                    Text("Details").font(.headline)
                    Spacer()
                    switch detailState {
                    case nil:
                        Button("Load Details") { model.appStore.loadDetail(for: app) }
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .loaded:
                        EmptyView()
                    case .unavailable:
                        Button("Retry") { model.appStore.loadDetail(for: app) }
                    }
                }
                if case .unavailable(let reason) = detailState {
                    Label("Details unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(reason)
                }
                // Same precedence as App Settings Utility's show_app_details: detail
                // lookup first where it is the better source, search fields as fallback.
                CompactValueRow(label: "Seller", value: detail?.seller ?? app.seller)
                CompactValueRow(label: "Version", value: detail?.version ?? app.version)
                CompactValueRow(label: "External version ID", value: detail?.externalVersionID, copyable: true)
                CompactValueRow(label: "Minimum OS", value: detail?.minimumOS ?? app.minimumOS)
                CompactValueRow(label: "Device families", value: detail.flatMap { $0.deviceFamilies.isEmpty ? nil : $0.deviceFamilies.joined(separator: ", ") })
                CompactValueRow(label: "Price", value: app.formattedPrice ?? detail?.price)
                CompactValueRow(label: "Age rating", value: detail?.ageRating ?? app.ageRating)
                CompactValueRow(label: "Device-based VPP", value: (detail?.vppDeviceLicensing ?? app.vppDeviceLicensing).map { $0 ? "Yes" : "No" })

                Text("Details come from an undocumented Apple endpoint (uclient-api.itunes.apple.com) and may change or be unavailable. Adding an app never depends on them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A stacked label/value pair for narrow panes. Missing values read "Unavailable".
struct CompactValueRow: View {
    let label: String
    let value: String?
    var copyable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                if let value {
                    Text(value)
                        .font(copyable ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if copyable {
                        Button { copy(value) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy \(label)")
                    }
                } else {
                    Text("Unavailable").foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }
}

struct PlatformBadges: View {
    let platforms: [AppStorePlatform]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(platforms) { platform in
                Text(platform.shortName)
                    .font(.caption2.weight(.semibold))
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// The 60-pt App Store artwork, loaded from Apple's image CDN.
private struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 20

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable()
        } placeholder: {
            RoundedRectangle(cornerRadius: size * 0.22).fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

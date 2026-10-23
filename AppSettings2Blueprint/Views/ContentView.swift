import AppKit
import SwiftUI

/// Sidebar (Lookup | Rule Set | Jamf) and the selected destination.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .blueprints
    @State private var isShowingFetchByID = false

    var body: some View {
        @Bindable var updates = updates
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
        }
        .navigationTitle("AppSettings2Blueprint")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProfilePicker()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if selection == .blueprints {
                    Button {
                        isShowingFetchByID = true
                    } label: {
                        Label("Fetch by ID", systemImage: "number")
                    }
                    .help("Fetch one Blueprint by ID")
                    .disabled(model.profileStore.selectedProfile == nil)

                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("List Blueprints")
                    .disabled(model.isListing || model.profileStore.selectedProfile == nil)
                }

                Button {
                    openWindow(id: WindowID.requestLog)
                } label: {
                    Label("Request Log", systemImage: "list.bullet.rectangle")
                }
                .help("Show every API request and response (secrets redacted)")
            }
        }
        .sheet(isPresented: $isShowingFetchByID) {
            FetchByIDSheet()
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
        }
        .onChange(of: model.profileStore.selectedProfile) {
            model.connectionDidChange()
            if selection == .blueprints && model.profileStore.selectedProfile != nil { model.refresh() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .blueprints:
            BlueprintsView()
        case .appStore:
            ComingLaterView(title: "App Store Lookup", systemImage: "bag", milestone: 3)
        case .builtInApps:
            ComingLaterView(title: "Apple Built-in Apps", systemImage: "apple.logo", milestone: 3)
        case .localApps:
            LocalAppsView()
        case .ruleSet:
            ComingLaterView(title: "Rule Set", systemImage: "checklist", milestone: 4)
        case nil:
            ContentUnavailableView("Select an Item", systemImage: "sidebar.left")
        }
    }
}

/// Placeholder for destinations built in a later milestone.
private struct ComingLaterView: View {
    let title: String
    let systemImage: String
    let milestone: Int

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Arrives in milestone \(milestone)."))
    }
}

/// Toolbar menu for switching between saved connections.
private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.profileStore
        if store.profiles.isEmpty {
            SettingsLink { Label("Add Connection…", systemImage: "plus") }
        } else {
            Picker("Connection", selection: Binding(
                get: { store.selectedProfileID },
                set: { store.selectedProfileID = $0 }
            )) {
                ForEach(store.profiles) { profile in
                    Text("\(profile.name) (\(profile.region.rawValue))").tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)
            .help("Active connection")
        }
    }
}

/// Fetches a single Blueprint by ID so its raw JSON can be inspected.
private struct FetchByIDSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var blueprintID = ""
    @State private var isFetching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fetch Blueprint by ID")
                .font(.headline)
            Text("Loads GET /blueprints/v1/blueprints/{id}.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Blueprint ID", text: $blueprintID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(fetch)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isFetching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fetch", action: fetch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blueprintID.trimmingCharacters(in: .whitespaces).isEmpty || isFetching)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func fetch() {
        isFetching = true
        errorMessage = nil
        Task {
            defer { isFetching = false }
            do {
                try await model.fetchBlueprint(id: blueprintID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    let model = AppModel()
    ContentView()
        .environment(model)
        .environment(model.updates)
}

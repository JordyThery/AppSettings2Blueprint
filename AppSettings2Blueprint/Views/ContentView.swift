import AppKit
import JTKit
import SwiftUI

/// Sidebar (Lookup | Rule Set | Jamf) and the selected destination.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    /// Restored from the last launch once; changes are saved as they happen.
    @State private var selection: SidebarItem? = UserDefaults.standard.string(forKey: ContentView.selectionKey)
        .flatMap(SidebarItem.init(rawValue:)) ?? .blueprints
    private static let selectionKey = "sidebarSelection"
    @State private var isShowingFetchByID = false

    var body: some View {
        @Bindable var updates = updates
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .overlay(alignment: .bottom) {
                    RuleSetStatusToast(selection: $selection)
                }
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
                    .help("Fetch one blueprint by ID")
                    .disabled(model.profileStore.selectedProfile == nil)

                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("List blueprints")
                    .disabled(model.isListing || model.profileStore.selectedProfile == nil)
                }

                Button {
                    openWindow(id: ActivityLogWindow.id)
                } label: {
                    Label("Activity Log", systemImage: "list.bullet.rectangle")
                }
                .help("Show sign-ins, Jamf API calls and App Store lookups (secrets redacted)")
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
        // Rule set edits from any view share the window's undo history.
        .onAppear { model.ruleSet.undoManager = undoManager }
        .onChange(of: undoManager) { model.ruleSet.undoManager = undoManager }
        .onChange(of: selection) { UserDefaults.standard.set(selection?.rawValue, forKey: Self.selectionKey) }
        .background(WindowEditedMarker(isEdited: model.ruleSet.isDirty))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .blueprints:
            BlueprintsView()
        case .appStore:
            AppStoreSearchView()
        case .builtInApps:
            BuiltInAppsView()
        case .localApps:
            LocalAppsView()
        case .ruleSet:
            RuleBuilderView()
        case nil:
            ContentUnavailableView("Select an Item", systemImage: "sidebar.left")
        }
    }
}

/// Sets the window's "edited" dot in the close button.
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let edited = isEdited
        DispatchQueue.main.async {
            view.window?.isDocumentEdited = edited
        }
    }
}

/// A short confirmation after something was added to the rule set from a lookup,
/// with a shortcut to the editor.
private struct RuleSetStatusToast: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        if let message = model.ruleSet.statusMessage {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                Text(message)
                    .lineLimit(2)
                if selection != .ruleSet {
                    Button("Show Rule Set") {
                        selection = .ruleSet
                        model.ruleSet.statusMessage = nil
                    }
                }
                Button {
                    model.ruleSet.statusMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ruleSetStatus")
            .padding(.bottom, 16)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(6))
                if model.ruleSet.statusMessage == message { model.ruleSet.statusMessage = nil }
            }
        }
    }
}

/// Toolbar menu for switching between saved connections, with Edit Connections…
/// (JTKit's `ConnectionPicker`, the same items as the Connection menu).
private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.profileStore
        ConnectionPicker(store: store.connections, selection: $store.selectedProfileID, itemTitle: \.menuTitle)
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
        // Return in the text field must obey the same conditions as the button.
        guard !isFetching, !blueprintID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

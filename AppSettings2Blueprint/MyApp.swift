import JTKit
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.forLaunch()

    var body: some Scene {
        Window("AppSettings2Blueprint", id: WindowID.main) {
            ContentView(initialSelection: model.savedSidebarSelection)
                .environment(model)
                .environment(model.updates)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.model = model }
                // A sandbox run (UI tests) makes no public lookups.
                .task { if !model.demo.isSandbox { await model.updates.checkAutomatically() } }
        }
        .environment(model.demo)
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(model: model)
        }

        AboutWindow(configuration: .appSettings2Blueprint)
            .environment(model.demo)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: model.activityLog,
            emptyDescription: "Sign-ins, Jamf API calls, retries and App Store lookups appear here as they happen."
        )
        .environment(model.demo)

        // JTKit's Settings window: General (Appearance, Backups), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            BackupSettingsSection()
                .environment(model)
        } tabs: {
            ConnectionsTab()
                .environment(model)
        }
        .environment(model.demo)
    }
}

enum WindowID {
    static let main = "main"
}

/// What to do with unsaved rule set changes when the app quits.
enum UnsavedChangesChoice {
    case save, discard, cancel
}

/// Asks to save an edited rule set before the app quits. Closing the window
/// loses nothing: the rule set stays in memory until the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// The question; replaced in tests.
    var ask: (RuleSetDocument) -> UnsavedChangesChoice = AppDelegate.askToSave
    /// Saves through the Save panel; false when canceled. Replaced in tests.
    var save: (RuleSetDocument) throws -> Bool = { try $0.saveWithPanel() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminateReply()
    }

    func terminateReply() -> NSApplication.TerminateReply {
        // A sandbox run is a UI test: nothing it edits is kept, and a question
        // would hold up the test runner's quit.
        guard let model, model.ruleSet.isDirty, !model.demo.isSandbox else { return .terminateNow }
        switch ask(model.ruleSet) {
        case .discard:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        case .save:
            do {
                return try save(model.ruleSet) ? .terminateNow : .terminateCancel
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
                return .terminateCancel
            }
        }
    }

    /// The standard macOS question, as for an edited document.
    private static func askToSave(_ document: RuleSetDocument) -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to the rule set “\(document.ruleSet.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        AppInfoCommands(appName: "AppSettings2Blueprint") {
            // The update sheet is presented on the main window.
            openWindow(id: WindowID.main)
            model.updates.checkManually()
        }
        // The toolbar picker's items, as JTKit's Connection menu.
        ConnectionCommands(
            store: model.profileStore.connections,
            selection: profileSelection(model),
            itemTitle: \.menuTitle
        ) {
            DemoModeToggle(demo: model.demo)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isListing)
            // The toolbar's Fetch by ID, also in the menu bar.
            Button("Fetch Blueprint by ID…") {
                openWindow(id: WindowID.main)
                model.isShowingFetchByID = true
            }
            .disabled(!model.hasActiveConnection)
        }
    }
}

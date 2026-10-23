import XCTest
import AppKit

/// Shared helpers for UI tests that drive the real Debug build. Each test
/// launches a fresh app: the rule set starts empty, the update check is off and
/// file panels open in a per-run temporary folder (see Scripts/run-ui-tests.sh).
class AppSettingsUITestCase: XCTestCase {
    var app: XCUIApplication!
    /// Where save and open panels start; created per test case.
    var workFolder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        workFolder = FileManager.default.temporaryDirectory.appending(path: "as2b-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        app = makeApp()
        launch()
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0 {
            print("UIDUMP-BEGIN\n\(app.debugDescription)\nUIDUMP-END")
            // The window as it looked at the failure; Scripts/run-ui-tests.sh exports it.
            let screenshot = app.windows.firstMatch.screenshot()
            add(XCTAttachment(screenshot: screenshot))
        }
        NSPasteboard.general.clearContents()
        app.terminate()
        try? FileManager.default.removeItem(at: workFolder)
    }

    /// The Debug build next to the test runner (not an installed release).
    func makeApp() -> XCUIApplication {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // …/Runner.app/Contents/PlugIns
            .deletingLastPathComponent() // …/Runner.app/Contents
            .deletingLastPathComponent() // …/Runner.app
            .deletingLastPathComponent() // Build/Products/Debug
        return XCUIApplication(url: products.appending(path: "AppSettings2Blueprint.app"))
    }

    /// Launch arguments land in the app's argument defaults domain, so they
    /// override the user's settings for this run only.
    func launch(section: String = "ruleSet") {
        app.launchArguments = [
            "-sidebarSelection", section,
            "-checksForUpdates", "NO",
            "-includeUserApplicationsFolder", "NO",
            "-NSNavLastRootDirectory", workFolder.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The main window did not open")
        if window.frame.width < 1200 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func relaunch(section: String = "ruleSet") {
        app.terminate()
        launch(section: section)
    }

    // MARK: Elements

    /// Any element whose label, title, value or identifier matches.
    func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR title == %@ OR value == %@ OR identifier == %@", text, text, text, text
        )).firstMatch
    }

    /// Any element whose label or value contains the text.
    func anyContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", text, text
        )).firstMatch
    }

    /// An element by accessibility identifier, whatever its type (SwiftUI exposes
    /// containers as groups or other elements depending on their content).
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A text field found by its placeholder.
    func field(placeholder prefix: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", prefix)).firstMatch
    }

    /// The live component JSON from the rule builder's preview.
    var componentJSON: String {
        let view = app.textViews["componentJSON"].firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 5), "The JSON preview is not visible")
        return view.value as? String ?? ""
    }

    /// Waits until the JSON preview satisfies `condition`.
    @discardableResult
    func waitForJSON(timeout: TimeInterval = 5, _ condition: (String) -> Bool, file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var json = componentJSON
        while !condition(json) && Date() < deadline {
            usleep(200_000)
            json = componentJSON
        }
        XCTAssertTrue(condition(json), "Unexpected component JSON:\n\(json)", file: file, line: line)
        return json
    }

    /// The text of the transient status toast, if one is showing.
    func statusMessage(timeout: TimeInterval = 5) -> String? {
        let toast = element("ruleSetStatus")
        guard toast.waitForExistence(timeout: timeout) else { return nil }
        // SwiftUI Text exposes its string as the value on macOS; the label is empty.
        return toast.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
            .joined(separator: " ")
    }

    // MARK: Actions

    func tap(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        // Sidebar rows and labels report themselves disabled; only controls are checked.
        if element.elementType != .staticText {
            let enabled = NSPredicate(format: "isEnabled == true")
            let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Disabled \(element)", file: file, line: line)
        }
        element.click()
    }

    func type(_ text: String, into element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        element.click()
        element.typeText(text)
    }

    /// Replaces a text field's contents.
    func replace(_ text: String, in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    /// Undo through the Edit menu, so it targets the window's undo manager
    /// rather than a text field's typing.
    func undo() {
        endEditing()
        tap(app.menuBars.menuBarItems["Edit"])
        tap(app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'")).firstMatch)
    }

    func redo() {
        endEditing()
        tap(app.menuBars.menuBarItems["Edit"])
        tap(app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Redo'")).firstMatch)
    }

    /// Ends text editing, as a user clicking elsewhere would. A field being
    /// edited keeps its own typing steps on the window's undo stack until then.
    func endEditing() {
        let preview = app.textViews["componentJSON"].firstMatch
        if preview.exists { preview.click() }
    }

    // MARK: Navigation

    /// Selects a sidebar row by its visible text.
    func openSidebar(_ label: String) {
        let row = app.outlines.staticTexts[label].firstMatch
        tap(row, timeout: 15)
    }

    /// The rule set row shows the rule set's name.
    func openRuleSet(named name: String = "Untitled Rule Set") {
        openSidebar(name)
        XCTAssertTrue(app.textViews["componentJSON"].waitForExistence(timeout: 10), "The rule builder did not open")
    }

    /// Selects an editor tab by (the start of) its title.
    func openTab(_ title: String) {
        let tab = app.tabs.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        tap(tab, timeout: 10)
    }

    /// Starts a new, empty rule set for `platform` ("iOS / iPadOS" or "macOS").
    func newRuleSet(_ platform: String) {
        tap(app.menuButtons["New"].firstMatch, timeout: 10)
        tap(app.menuItems["\(platform) Rule Set"])
        let discard = dialogButton("Discard and Start New")
        if discard.waitForExistence(timeout: 1) { discard.click() }
    }

    /// Filters Local Mac Apps and selects the row for `name`.
    func selectLocalApp(_ name: String) {
        openSidebar("Local Mac Apps")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "No search field")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(name)
        let row = app.outlines.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name))
            .allElementsBoundByIndex.first { $0.frame.minX > 200 }
        guard let row else {
            XCTFail("\(name) is not listed under Local Mac Apps")
            return
        }
        row.click()
        XCTAssertTrue(app.buttons["Add to AllowedBinaries…"].waitForExistence(timeout: 30), "\(name) was not inspected")
    }

    /// A button in a sheet or dialog, never its Touch Bar copy.
    func dialogButton(_ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label].firstMatch
        if inSheet.waitForExistence(timeout: 3) { return inSheet }
        let inDialog = app.dialogs.buttons[label].firstMatch
        if inDialog.exists { return inDialog }
        // Confirmation dialogs attached to a view appear as sheets of the window.
        return app.windows.firstMatch.sheets.buttons[label].firstMatch
    }

    // MARK: Panels

    /// Confirms a save panel with `name` in the per-run folder.
    func save(as name: String) {
        let panel = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The save panel did not open")
        let nameField = panel.textFields["saveAsNameTextField"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        goToFolder(workFolder.path(percentEncoded: false))
        tap(panel.buttons["OKButton"].firstMatch, timeout: 10)
        let replace = app.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 2) { replace.click() }
    }

    /// Opens `url` through an open panel's Go to Folder field.
    func open(_ url: URL) {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The open panel did not open")
        goToFolder(url.path(percentEncoded: false))
        tap(panel.buttons["OKButton"].firstMatch, timeout: 10)
    }

    private func goToFolder(_ path: String) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(path + "\n")
        sleep(1)
    }
}

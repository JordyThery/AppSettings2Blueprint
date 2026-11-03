import XCTest
import JTKitUITestSupport

/// The release check’s UI smoke tests, in demo mode:
/// the same answers every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours. The other UI tests
/// (`AppSettingsUITestCase`) are separate and not part of the release check.
final class DemoSmokeUITests: JTKitUITestCase {
    private let ipadBlueprint = "Contoso – iPad App Settings"

    override var appName: String { "AppSettings2Blueprint" }

    override var demoLaunchArguments: [String] {
        ["-sidebarSelection", "ruleSet", "-checksForUpdates", "NO", "-includeUserApplicationsFolder", "NO"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        // A click on the title bar first: in a fresh test runner, a key press
        // sent before any click (⌘, for Settings) crashes the runner in
        // CoreGraphics (CGS_REQUIRE_INIT). The release check runs each test
        // in its own runner.
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).click()
        if main.frame.width < 1200 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func test1Launch() {
        XCTAssertTrue(window(titled: appName).waitForExistence(timeout: 20), "The main window did not open")
        openBlueprints()
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        checkConnectionsEditor { settings in
            self.type(UUID().uuidString, into: settings.textFields.matching(NSPredicate(format: "placeholderValue == 'From Jamf Account'")).firstMatch)
            let fields = settings.textFields.allElementsBoundByIndex
            if let clientID = fields.last { self.type("jtktest-client", into: clientID) }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// Build a rule set, see its JSON, write it to a Contoso Blueprint and
    /// deploy it, with the app's confirmations.
    func test5MainTask() {
        // Straight after launch, without visiting Blueprints: Write to Jamf
        // lists the Blueprints itself and loads their details when the list
        // arrives, instead of staying on "Loading…".
        openSidebar("Editor")
        let json = app.textViews["componentJSON"].firstMatch
        XCTAssertTrue(json.waitForExistence(timeout: 10), "The editor did not open")
        type("com.apple.news\n", into: app.textFields["newBundleID"])
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'DeniedApps' AND value CONTAINS 'com.apple.news'"), object: json)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "The JSON doesn't show the rule: \(json.value ?? "")")

        tap(app.buttons["Write to Jamf…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Write to Jamf didn't open")
        tap(sheet.radioButtons["Existing Blueprint"], timeout: 10)
        tap(text(ipadBlueprint, in: sheet), timeout: 20)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value == 'Loading…'")).firstMatch.waitForNonExistence(timeout: 20),
                      "Blueprints in Write to Jamf stayed on Loading…")
        tap(sheet.buttons["Review Changes…"], timeout: 20)
        tap(sheet.buttons["Write to Blueprint"], timeout: 20)
        XCTAssertTrue(heading("Written and Verified", in: sheet).waitForExistence(timeout: 20), "The write wasn't verified")

        tap(sheet.buttons["Deploy…"], timeout: 10)
        let confirm = sheet.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'I confirm deploying' OR title BEGINSWITH 'I confirm deploying'")).firstMatch
        tap(confirm, timeout: 20)
        tap(sheet.buttons["Deploy"], timeout: 10)
        XCTAssertTrue(heading("Deployment Succeeded", in: sheet).waitForExistence(timeout: 90), "The deployment didn't succeed")
        tap(sheet.buttons["Done"])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "The sheet did not close")
    }

    func test6ActivityLog() {
        openBlueprints()
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    /// A saved connection whose region changes keeps its stored secret (Test
    /// Connection stays available), and Use This Connection in Settings leaves
    /// demo mode, as the toolbar picker does. Made-up values, in memory only.
    func test8RegionChangeAndUseThisConnection() {
        openSettings()
        let settings = settingsWindow
        tap(settings.toolbars.buttons["Connections"])
        addConnection("JTKTEST Region", in: settings)

        let region = settings.popUpButtons.firstMatch
        tap(region)
        tap(region.menuItems["Europe"], timeout: 5)
        XCTAssertTrue(settings.buttons["Save"].waitForEnabled(timeout: 5), "The region didn't change")
        XCTAssertFalse((settings.secureTextFields.firstMatch.placeholderValue ?? "").contains("Required after this change"),
                       "Changing the region asks for the secret again")
        XCTAssertTrue(settings.buttons["Test Connection"].isEnabled, "Test Connection is unavailable after a region change")
        tap(settings.buttons["Save"])

        // The first connection is in use; a second one isn't until it's chosen.
        addConnection("JTKTEST Second", in: settings)
        tap(settings.buttons["Use This Connection"], timeout: 5)
        let main = window(titled: appName)
        let leftDemo = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (title CONTAINS %@)", Self.demoTitleSuffix), object: main)
        XCTAssertEqual(XCTWaiter.wait(for: [leftDemo], timeout: 10), .completed, "Use This Connection didn't leave demo mode")
        close(settings)
    }

    /// Adds a connection with made-up values and saves it; its editor stays open.
    private func addConnection(_ name: String, in settings: XCUIElement) {
        tap(settings.buttons["Add Connection"].exists ? settings.buttons["Add Connection"] : settings.menuButtons["Add Connection"])
        let labelled = settings.textFields["Name"].firstMatch
        let nameField = labelled.waitForExistence(timeout: 2)
            ? labelled
            : settings.textFields.matching(NSPredicate(format: "value BEGINSWITH 'New '")).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The new connection's editor didn't open")
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        type(UUID().uuidString, into: settings.textFields.matching(NSPredicate(format: "placeholderValue == 'From Jamf Account'")).firstMatch)
        if let clientID = settings.textFields.allElementsBoundByIndex.last { type("jtktest-client", into: clientID) }
        type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        tap(settings.buttons["Save"])
    }

    // MARK: Helpers

    /// Jamf › Blueprints lists Contoso's sample Blueprints.
    private func openBlueprints(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Blueprints")
        XCTAssertTrue(text(ipadBlueprint, in: app).waitForExistence(timeout: 20),
                      "Contoso's Blueprints aren't listed", file: file, line: line)
    }

    /// A title marked as a heading, which exposes its string as the label.
    /// Found by subscript: a predicate query's firstMatch doesn't find it.
    private func heading(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts[string]
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}

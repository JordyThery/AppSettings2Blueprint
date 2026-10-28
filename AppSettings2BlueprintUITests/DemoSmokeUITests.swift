import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
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
        // The list first: Write to Jamf opened before any listing shows every
        // Blueprint as "Loading…" (reported to Jordy, 2026-10-28; not fixed here).
        openBlueprints()
        openSidebar("Editor")
        let json = app.textViews["componentJSON"].firstMatch
        XCTAssertTrue(json.waitForExistence(timeout: 10), "The rule builder did not open")
        type("com.apple.news\n", into: app.textFields["newBundleID"])
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'DeniedApps' AND value CONTAINS 'com.apple.news'"), object: json)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "The JSON doesn't show the rule: \(json.value ?? "")")

        tap(app.buttons["Write to Jamf…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Write to Jamf didn't open")
        tap(sheet.radioButtons["Existing Blueprint"], timeout: 10)
        tap(text(ipadBlueprint, in: sheet), timeout: 20)
        tap(sheet.buttons["Review Changes…"], timeout: 20)
        tap(sheet.buttons["Write to Blueprint"], timeout: 20)
        XCTAssertTrue(text("Written and verified", in: sheet).waitForExistence(timeout: 20), "The write wasn't verified")

        tap(sheet.buttons["Deploy…"], timeout: 10)
        let confirm = sheet.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'I confirm deploying' OR title BEGINSWITH 'I confirm deploying'")).firstMatch
        tap(confirm, timeout: 20)
        tap(sheet.buttons["Deploy"], timeout: 10)
        XCTAssertTrue(text("Deployment succeeded", in: sheet).waitForExistence(timeout: 90), "The deployment didn't succeed")
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

    // MARK: Helpers

    /// Jamf › Blueprints lists Contoso's sample Blueprints.
    private func openBlueprints(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Blueprints")
        XCTAssertTrue(text(ipadBlueprint, in: app).waitForExistence(timeout: 20),
                      "Contoso's Blueprints aren't listed", file: file, line: line)
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}

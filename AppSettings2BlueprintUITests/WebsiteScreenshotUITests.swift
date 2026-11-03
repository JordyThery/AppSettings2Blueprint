import XCTest
import JTKitUITestSupport

/// The three screenshots on jordythery.be, taken in demo mode with the sample
/// tenant "Contoso (Demo)". Not part of the release check (it runs only
/// `DemoSmokeUITests`), and the app's own scheme runs no UI tests, so ⌘U never
/// starts this. Run it by name; the screenshots are kept in the test result
/// as "as2b-editor", "as2b-lookup" and "as2b-write".
final class WebsiteScreenshotUITests: JTKitUITestCase {
    private let macBlueprint = "Contoso – App Settings for Macs"

    override var appName: String { "AppSettings2Blueprint" }

    override var demoLaunchArguments: [String] {
        ["-sidebarSelection", "ruleSet", "-checksForUpdates", "NO", "-includeUserApplicationsFolder", "NO",
         "-AppleInterfaceStyle", "Light"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Website screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    func testWebsiteScreenshots() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        zoom(main)

        // A macOS rule set: Firefox and the Apple baseline allowed, two Apple apps denied.
        openSidebar("Editor")
        XCTAssertTrue(app.textViews["componentJSON"].waitForExistence(timeout: 10), "The editor did not open")
        tap(app.menuButtons["New"].firstMatch, timeout: 10)
        tap(app.menuItems["macOS Rule Set"])
        let discard = dialogButton("Discard and Start New")
        if discard.waitForExistence(timeout: 1) { discard.click() }
        let name = app.textFields["Rule set name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "No rule set name field")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Company Macs\n")

        // Lookup: Safari inspected, with its slices' signing details.
        selectLocalApp("Safari")
        waitForToastToClear()
        sleep(1)
        keep(main.screenshot(), named: "as2b-lookup")

        for (name, list) in [("Firefox", "Allowed"), ("Chess", "Denied"), ("Photo Booth", "Denied")] {
            selectLocalApp(name)
            tap(app.buttons["Add to \(list)Binaries…"])
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The add-rule sheet didn't open")
            tap(sheet.buttons["Add 1 Rule"])
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The add-rule sheet didn't close")
        }

        openSidebar("Editor")
        let binariesTab = app.tabs.matching(NSPredicate(format: "label BEGINSWITH 'macOS: Binaries'")).firstMatch
        tap(binariesTab, timeout: 10)
        tap(app.buttons["Add Recommended Baseline"], timeout: 10)
        let json = app.textViews["componentJSON"].firstMatch
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'AllowedBinaries' AND value CONTAINS 'DeniedBinaries' AND value CONTAINS 'com.apple.Chess'"),
            object: json)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "The JSON doesn't show the rules: \(json.value ?? "")")
        json.click() // Ends editing, so no field shows a focus ring.
        waitForToastToClear()
        sleep(1)
        keep(main.screenshot(), named: "as2b-editor")

        // Write to Jamf: the review of the change to an existing Blueprint.
        tap(app.buttons["Write to Jamf…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Write to Jamf didn't open")
        tap(sheet.radioButtons["Existing Blueprint"], timeout: 10)
        tap(text(macBlueprint, in: sheet), timeout: 20)
        let review = sheet.buttons["Review Changes…"]
        XCTAssertTrue(review.waitForEnabled(timeout: 20), "Review Changes… never became available")
        review.click()
        XCTAssertTrue(sheet.buttons["Write to Blueprint"].waitForExistence(timeout: 20), "The review didn't open")
        sleep(1)
        keep(main.screenshot(), named: "as2b-write")
        tap(sheet.buttons["Cancel"])
    }

    // MARK: Helpers

    /// Filters Local Mac Apps and selects the row for `name`.
    private func selectLocalApp(_ name: String) {
        openSidebar("Local Mac Apps")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "No search field")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(name)
        let rows = app.outlines.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name))
        let deadline = Date().addingTimeInterval(30)
        var row: XCUIElement?
        while row == nil && Date() < deadline {
            row = rows.allElementsBoundByIndex.first { $0.frame.minX > 200 }
            if row == nil { usleep(500_000) }
        }
        guard let row else {
            XCTFail("\(name) is not listed under Local Mac Apps")
            return
        }
        row.click()
        XCTAssertTrue(app.buttons["Add to AllowedBinaries…"].waitForExistence(timeout: 30), "\(name) was not inspected")
    }

    /// Waits until the rule set's status toast has faded.
    private func waitForToastToClear() {
        let toast = app.descendants(matching: .any).matching(identifier: "ruleSetStatus").firstMatch
        XCTAssertTrue(toast.waitForNonExistence(timeout: 15), "The status toast didn't fade")
    }

    /// Zooms the window to fill the screen (drags don't move or resize it).
    private func zoom(_ window: XCUIElement) {
        let before = window.frame
        tap(app.menuBars.menuBarItems["Window"].firstMatch)
        tap(app.menuItems["Zoom"].firstMatch)
        sleep(1)
        if window.frame.height <= before.height {
            // The window was already zoomed: zooming toggled it back.
            tap(app.menuBars.menuBarItems["Window"].firstMatch)
            tap(app.menuItems["Zoom"].firstMatch)
            sleep(1)
        }
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

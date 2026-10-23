import XCTest

/// The About window, opened from the app menu, credits App Settings Utility.
final class AboutUITests: AppSettingsUITestCase {
    func testAboutShowsAcknowledgements() {
        // The Window menu lists the About window too; use the app menu's item.
        let appMenu = app.menuBars.menuBarItems["AppSettings2Blueprint"]
        appMenu.click()
        appMenu.menuItems["About AppSettings2Blueprint"].click()

        let about = app.windows["About AppSettings2Blueprint"]
        XCTAssertTrue(about.waitForExistence(timeout: 5), "The About window did not open")
        XCTAssertTrue(about.staticTexts["Acknowledgements"].exists)
        XCTAssertTrue(about.staticTexts["App Settings Utility by Anthony Darlow"].exists)
        XCTAssertTrue(about.links["cantscript/AppSettingsUtility"].exists)
        XCTAssertTrue(about.links["Stop Hunting for Bundle IDs & CDHashes"].exists)
        let licence = about.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Copyright (c) 2026 Anthony Darlow")).firstMatch
        XCTAssertTrue(licence.exists, "The licence text is missing")

        // For a visual check of the layout; Scripts/run-ui-tests.sh exports it.
        let screenshot = XCTAttachment(screenshot: about.screenshot())
        screenshot.name = "About"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

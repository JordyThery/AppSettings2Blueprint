import XCTest

/// The About window, opened from the app menu, credits App Settings Utility.
final class AboutUITests: AppSettingsUITestCase {
    func testAboutShowsAcknowledgements() {
        let appMenu = app.menuBars.menuBarItems["AppSettings2Blueprint"]
        appMenu.click()
        XCTAssertTrue(appMenu.menuItems["Check for Updates…"].exists, "Check for Updates… is missing from the app menu")
        appMenu.menuItems["About AppSettings2Blueprint"].click()

        let about = app.windows["About AppSettings2Blueprint"]
        XCTAssertTrue(about.waitForExistence(timeout: 5), "The About window did not open")
        // Like a standard Mac About window: close only.
        XCTAssertTrue(about.buttons["_XCUI:CloseWindow"].isEnabled)
        XCTAssertFalse(about.buttons["_XCUI:MinimizeWindow"].isEnabled, "Minimize should be dimmed")
        XCTAssertFalse(about.buttons["_XCUI:ZoomWindow"].isEnabled, "Zoom should be dimmed")

        XCTAssertTrue(about.staticTexts["AppSettings2Blueprint"].exists)
        XCTAssertTrue(about.links["github.com/JordyThery/AppSettings2Blueprint"].exists)
        XCTAssertTrue(about.staticTexts["Acknowledgements"].exists)
        XCTAssertTrue(about.staticTexts["App Settings Utility by Anthony Darlow"].exists)
        XCTAssertTrue(about.links["cantscript/AppSettingsUtility"].exists)
        XCTAssertTrue(about.links["Stop Hunting for Bundle IDs & CDHashes"].exists)
        // About shows the version only; update controls are in the app menu and Settings.
        XCTAssertFalse(about.buttons["Check for Updates…"].exists)
        XCTAssertFalse(about.checkBoxes["Check for updates daily"].exists)

        // The licence is folded away until opened.
        let disclosure = about.disclosureTriangles["MIT License"]
        XCTAssertTrue(disclosure.exists, "The licence disclosure is missing")
        disclosure.click()
        let licence = about.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Copyright (c) 2026 Anthony Darlow")).firstMatch
        XCTAssertTrue(licence.waitForExistence(timeout: 2), "The licence text is missing")

        // For a visual check of the layout.
        let screenshot = XCTAttachment(screenshot: about.screenshot())
        screenshot.name = "About"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

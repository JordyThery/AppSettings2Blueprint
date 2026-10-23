import XCTest

/// Drives the rule builder end to end: the walkthrough from the milestone 4
/// review, without a Jamf connection. Every test starts from a fresh launch.
final class RuleBuilderUITests: AppSettingsUITestCase {
    /// Typing, duplicates, both lists, undo and redo.
    func testIOSAppList() {
        openRuleSet()
        let bundleField = app.textFields["newBundleID"]
        type("com.apple.news\n", into: bundleField)
        waitForJSON { $0.contains(#""DeniedApps": ["#) && $0.contains("com.apple.news") }
        XCTAssertTrue(statusMessage()?.contains("Added 1 app") == true)

        type("com.apple.news\n", into: bundleField)
        XCTAssertTrue(statusMessage()?.contains("already listed") == true, "A duplicate was not reported")
        let json = componentJSON
        XCTAssertEqual(json.components(separatedBy: "com.apple.news").count - 1, 1, "The duplicate was added")

        tap(app.radioButtons["Allow list (AllowedApps)"])
        type("com.apple.mobilesafari\n", into: bundleField)
        waitForJSON { $0.contains("AllowedApps") && $0.contains("DeniedApps") }
        XCTAssertTrue(anyContaining("also has 1 entry").waitForExistence(timeout: 5), "No both-lists warning")
        XCTAssertTrue(anyContaining("warning").waitForExistence(timeout: 5), "The issues bar shows no warning")

        // Undo the Safari entry and the mode change; the deny list stays.
        undo()
        waitForJSON { !$0.contains("AllowedApps") }
        XCTAssertTrue(componentJSON.contains("com.apple.news"))
        redo()
        waitForJSON { $0.contains("com.apple.mobilesafari") }
    }

    /// Strategy sheet, allow-list baseline, exact-build slices and a CDHash error.
    func testMacBinariesFromInspector() {
        openRuleSet()
        newRuleSet("macOS")

        selectLocalApp("Calculator")
        tap(app.buttons["Add to AllowedBinaries…"])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'TeamID'")).firstMatch.exists)
        let preview = sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'com.apple.calculator'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The sheet does not show the TeamID + SigningID rule")
        tap(sheet.buttons["Add 1 Rule"])

        selectLocalApp("Safari")
        tap(app.buttons["Add to DeniedBinaries…"])
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let exact = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH 'This exact build'")).firstMatch
        tap(exact)
        XCTAssertEqual(sheet.checkBoxes.count, 3, "Safari should offer three slices")
        tap(sheet.buttons["Add 3 Rules"])

        openRuleSet()
        openTab("macOS: Binaries")
        XCTAssertTrue(element("baselineWarning").waitForExistence(timeout: 5), "No allow-list baseline warning")
        tap(app.buttons["Add Recommended Baseline"])
        XCTAssertTrue(element("baselineWarning").waitForNonExistence(timeout: 5), "The baseline warning stayed")
        let json = waitForJSON { $0.contains(#""AlwaysAllowManagedApps": true"#) }
        XCTAssertTrue(json.contains(#""TeamID": "*APPLE*""#))
        XCTAssertTrue(json.contains("com.apple.calculator"))
        XCTAssertEqual(json.components(separatedBy: #""CDHash""#).count - 1, 3, "Expected three CDHash rules")

        // A 39-character CDHash is an error and disables Save.
        let cdHashField = app.textFields.matching(NSPredicate(format: "value MATCHES '[0-9a-f]{40}'")).firstMatch
        XCTAssertTrue(cdHashField.waitForExistence(timeout: 5))
        cdHashField.click()
        cdHashField.typeKey(.end, modifierFlags: [])
        cdHashField.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(anyContaining("exactly 40 characters").waitForExistence(timeout: 5), "No CDHash length error")
        XCTAssertFalse(app.buttons["Save…"].isEnabled, "Save is enabled despite an error")
        undo()
        XCTAssertTrue(app.buttons["Save…"].waitForEnabled(timeout: 5), "Save stayed disabled after undo")
    }

    /// Composed identifier key, required justification, and the USER declaration.
    func testPrivacyDefaultsUseUserChannelOnMacOS() {
        openRuleSet()
        newRuleSet("macOS")
        selectLocalApp("Calculator")
        tap(app.buttons["Add Permission Defaults"])
        XCTAssertTrue(statusMessage()?.contains("Added permission defaults") == true)

        openRuleSet()
        openTab("Privacy")
        XCTAssertTrue(anyContaining("OrganizationJustification is required").waitForExistence(timeout: 5))
        let key = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'com.apple.calculator {'")).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5), "The composed identifier was not filled in")
        XCTAssertFalse(app.popUpButtons["Location Accuracy"].exists, "LocationAccuracy is offered on macOS")
        XCTAssertTrue(app.popUpButtons["Accessibility"].exists, "Accessibility is missing on macOS")

        type("Needed for dictating sums.", into: field(placeholder: "OrganizationJustification"))
        tap(app.popUpButtons["Microphone"])
        tap(app.menuItems["Allow"])
        let json = waitForJSON { $0.contains(#""Microphone": "Allow""#) }
        XCTAssertTrue(json.contains(#""channelType": "USER""#), "Privacy is not in a USER declaration")
        XCTAssertFalse(json.contains(#""channelType": "SYSTEM""#), "A SYSTEM declaration was written without binaries")
        XCTAssertTrue(anyContaining("No issues").waitForExistence(timeout: 5))
    }

    func testIOSHidesAccessibility() {
        openRuleSet()
        type("com.example.scanner\n", into: app.textFields["newBundleID"])
        openTab("Privacy")
        tap(app.buttons["Add Entry"])
        XCTAssertTrue(app.popUpButtons["Location Accuracy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.popUpButtons["Accessibility"].exists, "Accessibility is offered on iOS")
    }

    /// Shared iPad moves the iOS declaration to the USER channel, and back.
    func testSharedIPadUsesUserChannel() {
        openRuleSet()
        type("com.apple.news\n", into: app.textFields["newBundleID"])
        waitForJSON { $0.contains(#""channelType": "SYSTEM""#) }
        let sharedIPad = app.checkBoxes["Shared iPad"]
        tap(sharedIPad)
        waitForJSON { $0.contains(#""channelType": "USER""#) && $0.contains("com.apple.news") && !$0.contains("SYSTEM") }
        tap(sharedIPad)
        waitForJSON { $0.contains(#""channelType": "SYSTEM""#) }
        // Shared iPad applies to iOS only.
        tap(app.radioButtons["macOS"])
        let switchButton = dialogButton("Switch to macOS")
        if switchButton.waitForExistence(timeout: 3) { switchButton.click() }
        XCTAssertFalse(sharedIPad.waitForExistence(timeout: 2), "Shared iPad is offered on macOS")
    }

    /// Adding iOS apps to a non-empty macOS rule set is refused, not mixed in.
    func testPlatformGuard() {
        openRuleSet()
        newRuleSet("macOS")
        selectLocalApp("Calculator")
        tap(app.buttons["Add Permission Defaults"])

        openSidebar("Apple Built-in Apps")
        let books = app.outlines.staticTexts.matching(NSPredicate(format: "value == 'Books'")).firstMatch
        tap(books, timeout: 10)
        tap(app.buttons["Add to Rule Set"])
        XCTAssertTrue(statusMessage()?.contains("targets macOS") == true, "The platform guard did not explain itself")
        openRuleSet()
        XCTAssertFalse(componentJSON.contains("com.apple.iBooks"))
    }

    /// Save to a file, relaunch, open it again; asks before discarding edits.
    func testSaveAndOpen() throws {
        openRuleSet()
        type("com.apple.stocks\n", into: app.textFields["newBundleID"])
        tap(app.buttons["Save…"])
        save(as: "UI Test.appsettings.json")
        let file = workFolder.appending(path: "UI Test.appsettings.json")
        let saved = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) },
                                evaluatedWith: nil)
        wait(for: [saved], timeout: 10)
        XCTAssertTrue(app.staticTexts["UI Test.appsettings.json"].waitForExistence(timeout: 5), "The file name is not shown")

        relaunch()
        openRuleSet()
        XCTAssertFalse(componentJSON.contains("com.apple.stocks"))
        type("com.apple.tips\n", into: app.textFields["newBundleID"])
        tap(app.buttons["Open…"])
        let discard = dialogButton("Discard and Open…")
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Unsaved changes were not protected")
        tap(discard)
        open(file)
        let json = waitForJSON { $0.contains("com.apple.stocks") }
        XCTAssertFalse(json.contains("com.apple.tips"))
        XCTAssertFalse(app.staticTexts["Edited"].exists, "A freshly opened file shows as edited")
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

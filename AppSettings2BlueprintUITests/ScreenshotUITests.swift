import XCTest

/// Captures the README screenshots (docs/screenshot-*.png). Regenerate them with
/// `Scripts/run-ui-tests.sh ScreenshotUITests`; the images land in
/// /tmp/as2b-uitest-attachments. Keep hands off the Mac while it runs.
final class ScreenshotUITests: AppSettingsUITestCase {
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRuleSetScreenshot() {
        openRuleSet()
        let nameField = app.textFields["Rule set name"].firstMatch
        replace("iPad Classroom Baseline", in: nameField)
        let bundleField = app.textFields["newBundleID"]
        for bundleID in ["com.apple.news", "com.apple.stocks", "com.apple.tips", "com.apple.Maps"] {
            type("\(bundleID)\n", into: bundleField)
        }
        _ = waitForJSON { $0.contains("com.apple.Maps") }
        endEditing()
        // Let the "Added 1 app" toast fade before capturing.
        let toast = anyContaining("Added 1 app")
        _ = toast.waitForNonExistence(timeout: 10)
        capture("01-ruleset")
    }

    func testLocalAppsScreenshot() {
        selectLocalApp("Safari")
        capture("02-localapps")
    }
}

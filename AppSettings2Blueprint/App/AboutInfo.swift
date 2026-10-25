import Foundation
import JTKit

/// What the About window shows (JTKit's `AboutWindow`).
extension AboutConfiguration {
    static let appSettings2Blueprint = AboutConfiguration(
        appName: "AppSettings2Blueprint",
        author: "Created by Jordy Thery",
        summary: "Finds app identifiers, builds com.apple.configuration.app.settings rules and writes them to a Jamf Blueprint.",
        links: [
            AboutLink("github.com/JordyThery/AppSettings2Blueprint", address: "https://github.com/JordyThery/AppSettings2Blueprint"),
        ].compactMap { $0 },
        acknowledgements: [.appSettingsUtility]
    )
}

/// Credit for App Settings Utility, which the identifier discovery is based on,
/// with its MIT licence as it appears in THIRD-PARTY-NOTICES.md.
extension Acknowledgement {
    static let appSettingsUtilityRepositoryURL = URL(string: "https://github.com/cantscript/AppSettingsUtility")
    static let appSettingsUtilityBlogPostURL = URL(string: "https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/")

    static let appSettingsUtility = Acknowledgement(
        name: "App Settings Utility",
        author: "Anthony Darlow",
        summary: "Identifier discovery in AppSettings2Blueprint is based on Anthony Darlow’s App Settings Utility: the local app scan, the code signature fields and SigningState, the App Store lookup, the Apple built-in app list and the CSV formats.",
        links: [
            appSettingsUtilityRepositoryURL.map { AboutLink("cantscript/AppSettingsUtility", url: $0) },
            appSettingsUtilityBlogPostURL.map { AboutLink("Stop Hunting for Bundle IDs & CDHashes", url: $0) },
        ].compactMap { $0 },
        licence: """
            MIT License

            Copyright (c) 2026 Anthony Darlow

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
            """
    )
}

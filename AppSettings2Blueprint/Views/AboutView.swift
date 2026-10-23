import AppKit
import SwiftUI

/// The About window, opened from the app menu: app information and update controls.
struct AboutView: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UpdateChecker.automaticCheckKey) private var checksForUpdates = true

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)

                Text("AppSettings2Blueprint")
                    .font(.largeTitle.weight(.semibold))
                Text(version)
                    .foregroundStyle(.secondary)

                Text("Created by Jordy Thery")
                    .font(.title3.weight(.medium))
                    .padding(.top, 6)

                Text("Finds app identifiers, builds com.apple.configuration.app.settings rules and writes them to a Jamf Blueprint.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                    .padding(.top, 2)

                if let repository = URL(string: "https://github.com/JordyThery/AppSettings2Blueprint") {
                    Link("github.com/JordyThery/AppSettings2Blueprint", destination: repository)
                        .padding(.top, 6)
                }

                VStack(spacing: 6) {
                    Button("Check for Updates…") {
                        // The update sheet is presented on the main window.
                        openWindow(id: WindowID.main)
                        updates.checkManually()
                    }
                    Toggle("Check for updates daily", isOn: $checksForUpdates)
                        .toggleStyle(.checkbox)
                        .help("Ask GitHub once a day whether a newer release exists")
                }
                .padding(.top, 8)

                Divider()
                    .padding(.vertical, 12)

                AcknowledgementsView()
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Credit for App Settings Utility, which the identifier discovery is based on,
/// with its MIT licence as it appears in THIRD-PARTY-NOTICES.md.
struct AcknowledgementsView: View {
    static let repositoryURL = URL(string: "https://github.com/cantscript/AppSettingsUtility")
    static let blogPostURL = URL(string: "https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/")

    static let licence = """
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acknowledgements")
                .font(.title2.weight(.semibold))
            Text("App Settings Utility by Anthony Darlow")
                .font(.headline)
            Text("Identifier discovery in AppSettings2Blueprint is based on Anthony Darlow’s App Settings Utility: the local app scan, the code signature fields and SigningState, the App Store lookup, the Apple built-in app list and the CSV formats.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let repository = Self.repositoryURL {
                    Link("cantscript/AppSettingsUtility", destination: repository)
                }
                if let post = Self.blogPostURL {
                    Link("Stop Hunting for Bundle IDs & CDHashes", destination: post)
                }
            }
            Text(Self.licence)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview {
    AboutView()
        .environment(UpdateChecker())
        .frame(width: 560, height: 520)
}
#endif

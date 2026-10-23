import AppKit
import SwiftUI

/// The About window, opened from the app menu: app information and update controls.
struct AboutView: View {
    @Environment(UpdateChecker.self) private var updates
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
                    Button("Check for Updates…") { updates.checkManually() }
                    Toggle("Check for updates daily", isOn: $checksForUpdates)
                        .toggleStyle(.checkbox)
                        .help("Ask GitHub once a day whether a newer release exists")
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
#Preview {
    AboutView()
        .environment(UpdateChecker())
        .frame(width: 560, height: 520)
}
#endif

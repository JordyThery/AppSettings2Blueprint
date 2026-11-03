import AppKit
import JTKit
import SwiftUI

/// The exact com.jamf.ddm-strict component JSON the rule set produces.
struct JSONPreviewView: View {
    let document: RuleSetDocument

    var body: some View {
        let text = document.componentJSON.serializedString(pretty: true)
        let channels = DeclarationEncoder.channels(for: document.ruleSet)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Component JSON").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("\(channels.count) declaration\(channels.count == 1 ? "" : "s"): \(channels.joined(separator: " + "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(title: "Copy") { text }
            }
            .padding(10)
            if document.hasErrors {
                Label("Keys a platform doesn’t support are left out of this JSON. Fix the errors before saving.",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .labelStyle(.tintedIcon(.red))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            MonospacedTextView(text: text, accessibilityIdentifier: "componentJSON", scrollsToTopOnChange: false)
        }
    }
}

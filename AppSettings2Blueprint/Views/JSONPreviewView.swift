import AppKit
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
                    Text("Component JSON").font(.headline)
                    Text("\(channels.count) declaration\(channels.count == 1 ? "" : "s"): \(channels.joined(separator: " + "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(10)
            if document.hasErrors {
                Text("Keys a platform does not support are left out of this JSON. Fix the errors before saving.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            MonospacedTextView(text: text, accessibilityIdentifier: "componentJSON")
        }
    }
}

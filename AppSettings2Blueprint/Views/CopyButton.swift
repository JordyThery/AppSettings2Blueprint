import AppKit
import SwiftUI

/// Copies text to the pasteboard and confirms it: the button reads "Copied"
/// with a checkmark for a moment, and VoiceOver hears "Copied".
struct CopyButton: View {
    /// e.g. "Copy" or "Copy Bundle IDs"; for an icon-only button, the name
    /// VoiceOver reads, e.g. "Copy CDHash".
    let title: String
    var iconOnly = false
    /// The tooltip of an icon-only button; the title when nil.
    var help: String?
    let text: () -> String

    @State private var copied = false

    var body: some View {
        if iconOnly {
            IconButton(title: copied ? "Copied" : title, systemImage: symbol, help: help ?? title, action: copy)
        } else {
            Button(copied ? "Copied" : title, systemImage: symbol, action: copy)
        }
    }

    private var symbol: String { copied ? "checkmark" : "doc.on.doc" }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

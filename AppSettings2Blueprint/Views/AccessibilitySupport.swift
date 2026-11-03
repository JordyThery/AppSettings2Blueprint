import SwiftUI

/// A borderless icon-only button with a spoken name (VoiceOver, Voice
/// Control), a tooltip and a hit area of at least 24 by 24 points.
struct IconButton: View {
    /// What VoiceOver says, e.g. "Remove com.apple.news".
    let title: String
    let systemImage: String
    /// The tooltip; the title when nil.
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help ?? title)
    }
}

extension View {
    /// Tells VoiceOver what appeared, e.g. a sheet's result after its
    /// progress view, which it wouldn't otherwise notice.
    func announcesOnAppear(_ text: String) -> some View {
        onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

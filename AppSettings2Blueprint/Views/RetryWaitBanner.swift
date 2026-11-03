import JTKit
import SwiftUI

/// The wait before a retry (JTKit's `RequestWaits`), e.g. "Jamf asked to wait
/// 40 s", with Stop. Shown at the top of the write, scope and deploy sheets
/// while a wait lasts; nothing otherwise.
struct RetryWaitBanner: View {
    let waits: RequestWaits

    var body: some View {
        if let text = waits.statusText {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Stop") { waits.cancelAll() }
                    .help("Stop waiting: the request isn’t sent again")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("retryWait")
            .announcesOnAppear(text)
        }
    }
}

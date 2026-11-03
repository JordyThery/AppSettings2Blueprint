import AppKit
import SwiftUI

extension View {
    /// Lets people resize the sheet this view is the content of, down to
    /// `minWidth` by `minHeight`. SwiftUI's sheets on macOS keep their size;
    /// the content must be flexible (a `frame` with a maximum of `.infinity`).
    func resizableSheet(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        background(SheetResizing(minSize: NSSize(width: minWidth, height: minHeight)))
    }
}

/// Marks its window resizable once it's in one.
private struct SheetResizing: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView { WindowWatcher(minSize: minSize) }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowWatcher)?.apply()
    }

    final class WindowWatcher: NSView {
        let minSize: NSSize

        init(minSize: NSSize) {
            self.minSize = minSize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // Once more after SwiftUI has attached and sized the sheet.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// Only ever inside a sheet's content, so `window` is the sheet's.
        func apply() {
            guard let window else { return }
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            window.contentMinSize = minSize
        }
    }
}

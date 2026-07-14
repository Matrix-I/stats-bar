// AppKitBridges.swift — NSViewRepresentable plumbing the SwiftUI popover needs but SwiftUI
// can't express on its own: observing the popover window's visibility/screen, and forcing thin
// overlay scrollers on the backing NSScrollView.

import SwiftUI
import AppKit

/// Reports when the hosting window becomes visible / hidden. MenuBarExtra(.window) builds its
/// content once and just orders the popover window in and out, so SwiftUI's `.onAppear` doesn't
/// refire per open — observing the NSWindow directly is the reliable signal. `isVisible` tracks
/// ordered-in state (not mere occlusion), so covering the popover doesn't count as "closed".
final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    var onScreenHeight: ((CGFloat) -> Void)?
    private weak var observed: NSWindow?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observed else { evaluate(); return }
        let nc = NotificationCenter.default
        if let old = observed { nc.removeObserver(self, name: nil, object: old) }
        observed = window
        if let window {
            for name: NSNotification.Name in [NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didChangeScreenNotification,
                                              NSWindow.willCloseNotification] {
                nc.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
        }
        evaluate()
    }

    @objc private func windowChanged() {
        // Defer so order-out has settled before we read isVisible.
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func evaluate() {
        // Report the visibleFrame height of the display this popover currently sits on, so the
        // caller can cap to 80% of the *actual* screen (not a guessed one) in a multi-monitor setup.
        if let h = observed?.screen?.visibleFrame.height { onScreenHeight?(h) }
        let visible = observed?.isVisible ?? false
        guard visible != lastReported else { return }
        lastReported = visible
        onChange?(visible)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct WindowVisibilityReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onScreenHeight: ((CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> WindowVisibilityView {
        let v = WindowVisibilityView()
        v.onChange = onChange
        v.onScreenHeight = onScreenHeight
        return v
    }
    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.onChange = onChange
        nsView.onScreenHeight = onScreenHeight
    }
}

/// Placed inside a SwiftUI ScrollView, this walks up to the backing NSScrollView and forces the
/// thin *overlay* scrollers. Without it, a system set to "Show scroll bars: Always" gives the wide
/// legacy scroller (a permanent ~15pt track); overlay scrollers are ~half that and auto-hide.
struct OverlayScrollerConfigurator: NSViewRepresentable {
    final class FinderView: NSView {
        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.controlSize = .small
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.apply() } }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); DispatchQueue.main.async { [weak self] in self?.apply() } }
    }
    func makeNSView(context: Context) -> FinderView { FinderView(frame: .zero) }
    func updateNSView(_ nsView: FinderView, context: Context) {}
}

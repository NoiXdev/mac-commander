import AppKit
import SwiftUI

/// An invisible view that hands its window to `configure`, so the Settings window can be adjusted where
/// SwiftUI's scene modifiers fall short.
///
/// Two things SwiftUI does make a one-time call useless, both measured with a probe app on macOS 26:
/// - When the view enters the window, SwiftUI hasn't configured that window yet and overwrites whatever is set
///   then (style mask, autosave name). So every call is deferred to the next main-queue turn.
/// - SwiftUI resets the style mask when the Settings window closes, and reopening shows the same window again
///   without moving this view or updating it. So `configure` runs again whenever the window is shown
///   (occlusion changes), becomes key or is resized.
struct SettingsWindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.configure = configure
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.configure = configure
        view.scheduleConfigure()
    }

    final class AccessorView: NSView {
        var configure: (@MainActor (NSWindow) -> Void)?
        private var observers: [any NSObjectProtocol] = []

        private static let triggers: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
        ]

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            observers = Self.triggers.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleConfigure() }
                }
            }
            scheduleConfigure()
        }

        /// Runs `configure` on the next main-queue turn, after SwiftUI's own window setup.
        func scheduleConfigure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.configure?(window)
            }
        }
    }
}

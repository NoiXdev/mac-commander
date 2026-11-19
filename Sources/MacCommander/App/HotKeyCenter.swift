import AppKit
import Carbon
import MacCommanderCore

/// The app's one system-wide hotkey, registered with Carbon `RegisterEventHotKey` (no Accessibility or Input
/// Monitoring permission needed). One for the whole app, owned by `AppDelegate`.
@MainActor @Observable
final class HotKeyCenter {
    /// "MCmd": tags our hotkey's events.
    private static let signature: OSType = 0x4D43_6D64

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var registered: GlobalShortcut?
    @ObservationIgnored private var action: (@MainActor () -> Void)?
    @ObservationIgnored private var isHandlerInstalled = false
    /// Changes with every registration, so a stale press can't run a newer action.
    @ObservationIgnored private var currentID: UInt32 = 0

    /// Replaces the registered hotkey with `shortcut` (nil turns it off and returns true). Returns false when
    /// macOS refuses the shortcut (taken by the system or another app); the previous one is then registered again.
    /// Also false, leaving the previous one, for a shortcut that isn't `isValid` (a hand-edited preference without
    /// ⌘, ⌥ or ⌃ would take a bare key system-wide).
    func register(_ shortcut: GlobalShortcut?, action: @escaping @MainActor () -> Void) -> Bool {
        if let shortcut, !shortcut.isValid { return false }
        installHandlerIfNeeded()
        let previous = registered
        let previousAction = self.action
        unregister()
        guard let shortcut else { return true }
        if registerHotKey(shortcut) {
            self.action = action
            return true
        }
        if let previous, let previousAction, registerHotKey(previous) {
            self.action = previousAction
        }
        return false
    }

    private func registerHotKey(_ shortcut: GlobalShortcut) -> Bool {
        currentID &+= 1
        var ref: EventHotKeyRef?
        // Exclusive: fails when another app already registered the same combination.
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: currentID), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        registered = shortcut
        return true
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registered = nil
        action = nil
    }

    /// Installed once; the center lives as long as the app, so the handler gets it unretained.
    private func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                // The application event target dispatches on the main thread.
                let handled = MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().pressed(hotKeyID)
                }
                return handled ? noErr : OSStatus(eventNotHandledErr)
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        isHandlerInstalled = status == noErr
    }

    /// Runs the action for our current hotkey; false for any other hotkey event (it isn't ours to handle).
    private func pressed(_ hotKeyID: EventHotKeyID) -> Bool {
        guard hotKeyID.signature == Self.signature, hotKeyID.id == currentID, hotKeyRef != nil else { return false }
        action?()
        return true
    }
}

extension OpenRequestRouter {
    /// The global hotkey's action: unhides and activates the app, which brings its windows to the front. When no
    /// browser window is on screen it restores the latest minimized one, or opens a new one when none is open.
    func bringAppToFront() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        let windows = browserWindows
        guard !windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        if let minimized = windows.last(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
        } else if browserWindowCount == 0 {
            openNewWindow()
        }
    }
}

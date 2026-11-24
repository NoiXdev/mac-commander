import AppKit
import Carbon
import MacCommanderCore
import SwiftUI

/// A field that shows a global shortcut and records a new one: click it, then type the combination. Esc
/// cancels; a key without ⌘, ⌥ or ⌃ is ignored and recording goes on.
struct ShortcutRecorder: View {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut) -> Void
    private let recordingState = State(initialValue: false)

    var body: some View {
        let isRecording = recordingState.wrappedValue
        Text(label(isRecording: isRecording))
            .foregroundStyle(shortcut == nil || isRecording ? .secondary : .primary)
            .frame(minWidth: 120)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor)))
            .overlay(
                KeyCatcher(
                    onRecordingChange: { recordingState.wrappedValue = $0 },
                    onRecord: onRecord))
    }

    private func label(isRecording: Bool) -> String {
        if isRecording { return L10n.string("settings.shortcuts.recording", "Type shortcut") }
        return shortcut?.displayString ?? L10n.string("settings.shortcuts.empty", "Click to record")
    }
}

/// The transparent view that takes the click, becomes first responder and captures the next key.
private struct KeyCatcher: NSViewRepresentable {
    let onRecordingChange: (Bool) -> Void
    let onRecord: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> RecorderKeyView {
        let view = RecorderKeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderKeyView, context: Context) {
        view.onRecordingChange = onRecordingChange
        view.onRecord = onRecord
    }
}

private final class RecorderKeyView: NSView {
    var onRecordingChange: (Bool) -> Void = { _ in }
    var onRecord: (GlobalShortcut) -> Void = { _ in }
    /// Only a click starts recording, so the Settings window never makes this its first responder by itself.
    private var isClicked = false
    /// While recording: ends it on a click anywhere else, so a later keypress isn't taken by surprise.
    private var clickMonitor: Any?

    override var acceptsFirstResponder: Bool { isClicked }

    override func mouseDown(with event: NSEvent) {
        isClicked = true
        if window?.makeFirstResponder(self) != true {
            isClicked = false
        }
    }

    override func becomeFirstResponder() -> Bool {
        onRecordingChange(true)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            let isInside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            if !isInside { endRecording() }
            return event
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        isClicked = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        onRecordingChange(false)
        return true
    }

    /// Recording also ends when the window stops being key (another window or app was activated).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification,
                object: newWindow)
        }
        endRecording()
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        endRecording()
    }

    private func endRecording() {
        if let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    /// ⌘ combinations arrive here before the menus see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: GlobalShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            endRecording()
            return
        }
        guard let key = Self.keyName(for: event) else { return }
        let shortcut = GlobalShortcut(keyCode: event.keyCode, modifiers: modifiers, key: key)
        guard shortcut.isValid else { return }
        window?.makeFirstResponder(nil)
        onRecord(shortcut)
    }

    private static let specialKeys: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_Escape: "Esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, keyCode) in functionKeys.enumerated() {
            names[keyCode] = "F\(index + 1)"
        }
        return names
    }()

    /// The key's label: a name for special keys, otherwise the typed character in upper case. Nil for keys
    /// without a printable label.
    private static func keyName(for event: NSEvent) -> String? {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty,
            !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return characters
    }
}

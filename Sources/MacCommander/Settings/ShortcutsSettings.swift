import MacCommanderCore
import SwiftUI

/// Shortcut settings: the global hotkey that brings MacCommander to the front from anywhere.
struct ShortcutsSettings: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(OpenRequestRouter.self) private var router
    @Environment(HotKeyCenter.self) private var hotKeys
    /// Set when the last recorded shortcut couldn't be registered.
    private let hotKeyFailedState = State(initialValue: false)

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(L10n.string("settings.shortcuts.globalHotkey", "Global hotkey")) {
                        HStack {
                            ShortcutRecorder(shortcut: preferences.preferences.globalShortcut, onRecord: recordHotKey)
                            Button(L10n.string("settings.shortcuts.clear", "Clear"), action: clearHotKey)
                                .disabled(preferences.preferences.globalShortcut == nil)
                        }
                    }
                    if hotKeyFailedState.wrappedValue {
                        L10n.text("settings.shortcuts.inUse", "This shortcut is already in use")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Registers the shortcut first and stores it only when that worked.
    private func recordHotKey(_ shortcut: GlobalShortcut) {
        let router = router
        if hotKeys.register(shortcut, action: { router.bringAppToFront() }) {
            preferences.preferences.globalShortcut = shortcut
            hotKeyFailedState.wrappedValue = false
        } else {
            hotKeyFailedState.wrappedValue = true
        }
    }

    private func clearHotKey() {
        _ = hotKeys.register(nil) {}
        preferences.preferences.globalShortcut = nil
        hotKeyFailedState.wrappedValue = false
    }
}

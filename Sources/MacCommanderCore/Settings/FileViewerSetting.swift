import Foundation

/// Reads and writes string values in the user's global defaults domain (`NSGlobalDomain`).
/// A nil value removes the key.
public protocol GlobalDefaultsStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// The real global-domain store, backed by CFPreferences for the current user on any host.
public struct CFGlobalDefaultsStore: GlobalDefaultsStore {
    public init() {}

    public func string(forKey key: String) -> String? {
        CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
    }

    public func set(_ value: String?, forKey key: String) {
        CFPreferencesSetValue(
            key as CFString, value as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Whether this app is the system's file viewer ("Show in Finder"), kept in the global `NSFileViewer` default.
public struct FileViewerSetting: Sendable {
    public static let key = "NSFileViewer"

    private let bundleIdentifier: String
    private let store: GlobalDefaultsStore

    public init(bundleIdentifier: String, store: GlobalDefaultsStore) {
        self.bundleIdentifier = bundleIdentifier
        self.store = store
    }

    /// True while the stored viewer is this app, compared case-insensitively.
    public var isEnabled: Bool {
        store.string(forKey: Self.key)?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }

    /// On makes this app the viewer. Off removes the key only while it is ours, leaving another app's choice alone.
    public func setEnabled(_ on: Bool) {
        if on {
            store.set(bundleIdentifier, forKey: Self.key)
        } else if isEnabled {
            store.set(nil, forKey: Self.key)
        }
    }
}

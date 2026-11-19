import Foundation

/// A system-wide hotkey recorded by the user (virtual key code plus modifiers).
public struct GlobalShortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    /// Virtual key code.
    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// The key's label captured when recording, e.g. "M", "F5", "Space".
    public var key: String

    public init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A global hotkey needs command, option or control (shift alone would hijack typing).
    public var isValid: Bool {
        !modifiers.isDisjoint(with: [.command, .option, .control])
    }

    /// Modifier symbols in the order ⌃⌥⇧⌘, then the key label.
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    /// Carbon modifier mask (literal values; Core doesn't import Carbon).
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 256 }  // cmdKey
        if modifiers.contains(.shift) { mask |= 512 }  // shiftKey
        if modifiers.contains(.option) { mask |= 2048 }  // optionKey
        if modifiers.contains(.control) { mask |= 4096 }  // controlKey
        return mask
    }
}

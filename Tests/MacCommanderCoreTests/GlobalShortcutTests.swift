import Foundation
import Testing

@testable import MacCommanderCore

struct GlobalShortcutTests {
    private func shortcut(_ m: GlobalShortcut.Modifiers, key: String = "M") -> GlobalShortcut {
        GlobalShortcut(keyCode: 46, modifiers: m, key: key)
    }

    @Test func validityNeedsCommandOptionOrControl() {
        #expect(!shortcut([.shift]).isValid)
        #expect(!shortcut([]).isValid)
        #expect(shortcut([.option]).isValid)
        #expect(shortcut([.control, .shift]).isValid)
    }

    @Test func displayOrder() {
        #expect(shortcut([.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘M")
    }

    @Test func carbonMask() {
        #expect(shortcut([.command, .option]).carbonModifiers == 2304)
        #expect(shortcut([.control, .shift]).carbonModifiers == 4608)
    }

    @Test func codableRoundTrip() throws {
        let original = shortcut([.command, .option], key: "F5")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(GlobalShortcut.self, from: data) == original)
    }
}

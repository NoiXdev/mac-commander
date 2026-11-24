import AppKit
import MacCommanderCore
import SwiftUI

/// Settings ▸ Open With: per-extension rules that pick the app a file opens with inside MacCommander only
/// (`OpenWithRules`). Lists the rules sorted by extension, flags a rule whose app is gone, and adds a rule
/// through an extension field and an app picker. macOS's own associations stay untouched.
struct OpenWithSettings: View {
    @Environment(PreferencesStore.self) private var preferences

    /// The extension typed into the add row.
    @State private var newExtension = ""
    /// Each rule's located app and icon, keyed by extension. Filled off the main actor by `lookUp(_:)`.
    @State private var lookups: [String: Lookup] = [:]

    /// What `lookUp(_:)` found for one rule. `rule` is the rule it was found for, so a result for a rule that
    /// has since been replaced is never shown.
    private struct Lookup: Sendable {
        let rule: OpenWithRule
        let app: URL?
        let icon: NSImage?
    }

    private var rules: OpenWithRules { preferences.preferences.openWithRules }

    /// The add row's extension as a rule key, or nil while it can't be one ("Choose App…" stays disabled).
    private var normalizedNewExtension: String? { OpenWithRules.normalizedExtension(newExtension) }

    var body: some View {
        Form {
            Section {
                ForEach(rules.extensions, id: \.self) { ext in
                    if let rule = rules[ext] {
                        row(ext, rule)
                    }
                }
                addRow
            } header: {
                L10n.text("settings.openWith.rules.header", "Rules")
            } footer: {
                L10n.text("settings.openWith.rules.footer", "Rules apply only in MacCommander. Without a rule, files open with the app macOS assigns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: rules) {
            let rules = rules
            let found = await PathQueries.run { Self.lookUp(rules) }
            guard !Task.isCancelled else { return }
            lookups = found
        }
    }

    // MARK: Rows

    /// Width of the longest listed ".ext" at the system font, so every row's app name starts at the same x and no
    /// extension is truncated. Rows never get narrower than 60 pt.
    private var extensionColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return rules.extensions
            .map { (".\($0)" as NSString).size(withAttributes: [.font: font]).width }
            .max()
            .map { ceil($0) } ?? 0
    }

    private func row(_ ext: String, _ rule: OpenWithRule) -> some View {
        // Until the lookup for this very rule is done, the row shows the stored name and no warning.
        let lookup = lookups[ext].flatMap { $0.rule == rule ? $0 : nil }
        let missing = lookup.map { $0.app == nil } ?? false
        return HStack {
            Text(verbatim: ".\(ext)")
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: max(60, extensionColumnWidth), alignment: .leading)
            if missing {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help(L10n.string("settings.openWith.notInstalled.help", "Files with this extension open with the app macOS assigns until you choose another app."))
            } else if let icon = lookup?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Button(rule.appName) { chooseApp(for: ext) }
                .buttonStyle(.link)
                .lineLimit(1)
                .help(L10n.string("settings.openWith.changeApp", "Choose another app"))
            if missing {
                L10n.text("settings.openWith.notInstalled", "Not installed")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(L10n.string("settings.openWith.notInstalled.help", "Files with this extension open with the app macOS assigns until you choose another app."))
            }
            Spacer()
            Button {
                preferences.preferences.openWithRules.remove(ext)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            // `.help` is the hover tooltip, `.accessibilityLabel` what VoiceOver reads: the same text on purpose.
            .help(L10n.string("settings.openWith.remove", "Remove"))
            .accessibilityLabel(L10n.string("settings.openWith.remove", "Remove"))
        }
    }

    /// An extension field and "Choose App…". The field has an empty title and a `prompt:`: in a grouped form a
    /// `TextField` title is a permanent label, not a placeholder (macSCP's fix).
    private var addRow: some View {
        LabeledContent(L10n.string("settings.openWith.extension", "Extension")) {
            HStack {
                TextField("", text: $newExtension, prompt: L10n.text("settings.openWith.extensionPlaceholder", "php"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .accessibilityLabel(L10n.string("settings.openWith.extension", "Extension"))
                    .onSubmit(addRule)
                Button(L10n.string("settings.openWith.chooseApp", "Choose App…"), action: addRule)
                    // Gated on the normalized value: "." or "a.b" trim to text but can't be a rule key.
                    .disabled(normalizedNewExtension == nil)
            }
        }
    }

    // MARK: Actions

    private func addRule() {
        guard let ext = normalizedNewExtension else { return }
        if chooseApp(for: ext) { newExtension = "" }
    }

    /// Asks for an app and makes it the rule for `ext`, replacing any rule there. Returns whether one was picked.
    @discardableResult
    private func chooseApp(for ext: String) -> Bool {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L10n.string("settings.openWith.panelPrompt", "Choose")
        guard panel.runModal() == .OK, let app = panel.url else { return false }
        // Reading the bundle id and display name here, on the main actor, is a single local read of the one app
        // the user just picked in the panel; every other lookup in this pane runs on `PathQueries.run`.
        let rule = OpenWithRule(
            bundleIdentifier: Bundle(url: app)?.bundleIdentifier,
            appPath: app.path(percentEncoded: false),
            appName: Self.displayName(of: app))
        preferences.preferences.openWithRules.set(rule, for: ext)
        return true
    }

    /// The app's name as the Finder shows it, without a trailing ".app".
    private static func displayName(of app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
        guard name.lowercased().hasSuffix(".app"), name.count > 4 else { return name }
        return String(name.dropLast(4))
    }

    // MARK: Lookup

    /// Each rule's app (nil when it's missing) and that app's icon. Asks Launch Services and the file system,
    /// so it runs on the blocking-I/O queue (`PathQueries.run`), never on the main actor or in `body`.
    private nonisolated static func lookUp(_ rules: OpenWithRules) -> [String: Lookup] {
        let locator = WorkspaceApplicationLocator()
        var found: [String: Lookup] = [:]
        for ext in rules.extensions {
            guard let rule = rules[ext] else { continue }
            let app = OpenWithRules.application(for: rule, locator: locator)
            let icon = app.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            found[ext] = Lookup(rule: rule, app: app, icon: icon)
        }
        return found
    }
}

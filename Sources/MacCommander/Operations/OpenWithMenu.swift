import AppKit
import MacCommanderCore

/// The "Open With" submenu for a right-click on files.
@MainActor
enum OpenWithMenu {
    /// The submenu shows "Loading…" until the applications are known: content types, Launch Services and
    /// app icons are looked up off the main actor, since the files may be on a network volume.
    static func make(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let loading = NSMenuItem(title: String(localized: "Loading…"), action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        item.submenu = menu
        Task { @MainActor in
            let choices = await applications(for: urls)
            fill(menu, with: choices, urls: urls)
        }
        return item
    }

    /// Above this many distinct content types, the menu offers only "Other…".
    nonisolated static let maxContentTypes = 50

    private struct App: Sendable {
        let url: URL
        let name: String
        let icon: NSImage
    }

    private struct Choices: Sendable {
        /// The first item's default app, when it opens all items.
        var defaultApp: App?
        /// Apps that open all items, sorted by name, without the default app.
        var others: [App] = []
    }

    private static func fill(_ menu: NSMenu, with choices: Choices?, urls: [URL]) {
        menu.removeAllItems()
        if let choices {
            if let app = choices.defaultApp {
                menu.addItem(appItem(app, title: app.name + " " + String(localized: "(default)"), urls: urls))
                if !choices.others.isEmpty { menu.addItem(.separator()) }
            }
            var seen = Set<String>()
            for app in choices.others where seen.insert(app.name).inserted {
                menu.addItem(appItem(app, title: app.name, urls: urls))
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        }
        menu.addItem(ActionMenuItem(String(localized: "Other…")) { chooseApp(for: urls) })
    }

    /// Launch Services is queried once per content type, not per item: a huge selection of a few types
    /// stays cheap. nil with too many types: the menu then offers only "Other…".
    /// On the blocking-I/O queue (`PathQueries.run`), not the cooperative pool.
    private static func applications(for urls: [URL]) async -> Choices? {
        await PathQueries.run { applicationsNow(for: urls) }
    }

    nonisolated private static func applicationsNow(for urls: [URL]) -> Choices? {
        guard let samples = samples(of: urls) else { return nil }
        let workspace = NSWorkspace.shared
        var defaultApp = urls.first.flatMap { workspace.urlForApplication(toOpen: $0) }
        // With several items, only apps that open all of them.
        var common: Set<URL>?
        for url in samples {
            let apps = Set(workspace.urlsForApplications(toOpen: url))
            common = common.map { $0.intersection(apps) } ?? apps
        }
        // The first item's default app is offered only if it opens all of them.
        if urls.count > 1, let app = defaultApp, common?.contains(app) != true { defaultApp = nil }
        var choices = Choices()
        choices.defaultApp = defaultApp.map { app($0) }
        choices.others = (common ?? [])
            .filter { $0 != defaultApp }
            .map { app($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return choices
    }

    /// One URL per distinct content type (`contentTypeKey`, else the lowercased path extension), in order;
    /// nil if there are more than `maxContentTypes`.
    nonisolated private static func samples(of urls: [URL]) -> [URL]? {
        var seen = Set<String>()
        var samples: [URL] = []
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            let key = type ?? "extension:" + url.pathExtension.lowercased()
            guard seen.insert(key).inserted else { continue }
            if seen.count > maxContentTypes { return nil }
            samples.append(url)
        }
        return samples
    }

    nonisolated private static func app(_ url: URL) -> App {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return App(url: url, name: name, icon: icon)
    }

    private static func appItem(_ app: App, title: String, urls: [URL]) -> NSMenuItem {
        let item = ActionMenuItem(title) { open(urls, with: app.url) }
        item.image = app.icon
        return item
    }

    private static func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func chooseApp(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Open")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let app = panel.url else { return }
            open(urls, with: app)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}

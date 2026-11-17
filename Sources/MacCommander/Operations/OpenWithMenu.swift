import AppKit

/// The "Open With" submenu for a right-click on files.
@MainActor
enum OpenWithMenu {
    static func make(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let workspace = NSWorkspace.shared

        // Launch Services is queried once per content type, not per item: a huge selection of a few types
        // stays cheap. With too many types the menu offers only "Other…".
        guard let samples = samples(of: urls) else {
            menu.addItem(ActionMenuItem(String(localized: "Other…")) { chooseApp(for: urls) })
            item.submenu = menu
            return item
        }
        var defaultApp = urls.first.flatMap { workspace.urlForApplication(toOpen: $0) }
        // With several items, only apps that open all of them.
        var common: Set<URL>?
        for url in samples {
            let apps = Set(workspace.urlsForApplications(toOpen: url))
            common = common.map { $0.intersection(apps) } ?? apps
        }
        // The first item's default app is offered only if it opens all of them.
        if urls.count > 1, let app = defaultApp, common?.contains(app) != true { defaultApp = nil }
        let others = (common ?? [])
            .filter { $0 != defaultApp }
            .map { (url: $0, name: displayName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let defaultApp {
            menu.addItem(appItem(defaultApp, title: displayName(defaultApp) + " " + String(localized: "(default)"), urls: urls))
            if !others.isEmpty { menu.addItem(.separator()) }
        }
        var seen = Set<String>()
        for app in others where seen.insert(app.name).inserted {
            menu.addItem(appItem(app.url, title: app.name, urls: urls))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem(String(localized: "Other…")) { chooseApp(for: urls) })
        item.submenu = menu
        return item
    }

    /// Above this many distinct content types, the menu offers only "Other…".
    static let maxContentTypes = 50

    /// One URL per distinct content type (`contentTypeKey`, else the lowercased path extension), in order;
    /// nil if there are more than `maxContentTypes`.
    private static func samples(of urls: [URL]) -> [URL]? {
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

    private static func displayName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func appItem(_ app: URL, title: String, urls: [URL]) -> NSMenuItem {
        let item = ActionMenuItem(title) { open(urls, with: app) }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
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

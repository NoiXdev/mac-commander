import Foundation

/// The app a rule opens files with. `bundleIdentifier` is preferred; `appPath` is the fallback.
public struct OpenWithRule: Codable, Equatable, Sendable {
    public var bundleIdentifier: String?
    public var appPath: String
    public var appName: String

    public init(bundleIdentifier: String? = nil, appPath: String, appName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.appName = appName
    }
}

/// Per-extension "Open With" rules that apply only inside MacCommander. Keys are normalized extensions.
public struct OpenWithRules: Codable, Equatable, Sendable {
    private var byExtension: [String: OpenWithRule] = [:]

    public init() {}

    /// Lowercased extension without its leading dot, or nil when `typed` can't be an extension.
    /// Only one leading dot is dropped, so `..md` is invalid.
    public static func normalizedExtension(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty, !text.contains("."), !text.contains("/") else { return nil }
        return text.lowercased()
    }

    /// The normalized extensions that have a rule, sorted.
    public var extensions: [String] { byExtension.keys.sorted() }

    public subscript(ext: String) -> OpenWithRule? {
        Self.normalizedExtension(ext).flatMap { byExtension[$0] }
    }

    public mutating func set(_ rule: OpenWithRule, for ext: String) {
        guard let key = Self.normalizedExtension(ext) else { return }
        byExtension[key] = rule
    }

    public mutating func remove(_ ext: String) {
        guard let key = Self.normalizedExtension(ext) else { return }
        byExtension[key] = nil
    }

    /// The rule for the file's last extension, ignoring case.
    public func rule(for url: URL) -> OpenWithRule? {
        self[url.pathExtension]
    }

    // MARK: Resolving apps

    /// The rule's app: the bundle identifier's app first, then the stored path if something is there; nil
    /// when the app is missing. The locator may block; call this off the main actor.
    public static func application(for rule: OpenWithRule, locator: some ApplicationLocating) -> URL? {
        if let id = rule.bundleIdentifier, let url = locator.applicationURL(bundleIdentifier: id) { return url }
        guard !rule.appPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: rule.appPath, isDirectory: true)
        return locator.applicationExists(at: url) ? url : nil
    }

    /// The located app of the rule for `url`, or nil when there is no rule, its app is missing, or the rule
    /// doesn't apply: never to directories (folders and packages), and with `skippingArchives` not to pure
    /// archives (`ArchiveFormats.isArchive`), which MacCommander browses instead of opening.
    private func ruleApplication(
        for url: URL, locator: some ApplicationLocating, skippingArchives: Bool
    ) -> URL? {
        guard let rule = rule(for: url) else { return nil }
        if skippingArchives, ArchiveFormats.isArchive(url) { return nil }
        guard !locator.isDirectory(url) else { return nil }
        return Self.application(for: rule, locator: locator)
    }

    /// `urls` split by the app that opens them: a located rule app, or nil for the system default. Folders,
    /// packages and pure archives always get the system default. Groups keep the order of each app's first
    /// appearance and URLs keep their order inside a group. Off the main actor.
    public func groups(for urls: [URL], locator: some ApplicationLocating) -> [OpenGroup] {
        var groups: [OpenGroup] = []
        for url in urls {
            let app = ruleApplication(for: url, locator: locator, skippingArchives: true)
            if let index = groups.firstIndex(where: { Self.sameApp($0.app, app) }) {
                groups[index].urls.append(url)
            } else {
                groups.append(OpenGroup(app: app, urls: [url]))
            }
        }
        return groups
    }

    /// Which app the Open With menu marks as the default for `urls`; see `MenuDefault`. Folders and packages
    /// count as having no rule; archives keep theirs (the menu is the only place a `zip` rule matters).
    /// Off the main actor.
    public func menuDefault(for urls: [URL], locator: some ApplicationLocating) -> MenuDefault {
        let ruleApps = urls.map { ruleApplication(for: $0, locator: locator, skippingArchives: false) }
        guard ruleApps.contains(where: { $0 != nil }) else { return .system }
        var shared: URL?
        for (url, ruleApp) in zip(urls, ruleApps) {
            guard let app = ruleApp ?? locator.systemDefaultApplication(for: url) else { return .none }
            if let shared, !Self.sameApp(shared, app) { return .none }
            shared = shared ?? app
        }
        guard let shared else { return .none }
        return .app(shared)
    }

    /// Two app URLs name the same app; a trailing slash or `..` doesn't matter.
    private static func sameApp(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL.path == rhs?.standardizedFileURL.path
    }

    // MARK: Coding as a JSON object `{ext: rule}`

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }


    /// Lenient: entries that don't decode, and keys that don't normalize, are dropped; the rest kept.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: Key.self) else { return }
        for key in c.allKeys {
            if let rule = try? c.decode(OpenWithRule.self, forKey: key) {
                set(rule, for: key.stringValue)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (ext, rule) in byExtension {
            try c.encode(rule, forKey: Key(stringValue: ext))
        }
    }
}

/// Files that open with one app. `app == nil` means each file's system default.
public struct OpenGroup: Equatable, Sendable {
    public var app: URL?
    public var urls: [URL]

    public init(app: URL?, urls: [URL]) {
        self.app = app
        self.urls = urls
    }
}

/// The Open With menu's default choice for a selection.
public enum MenuDefault: Equatable, Sendable {
    /// No file has a located rule app: the menu keeps its usual choice.
    case system
    /// Every file opens with this app (its rule app, else its system default) and at least one has a rule.
    case app(URL)
    /// The files open with different apps, or one has no app.
    case none
}

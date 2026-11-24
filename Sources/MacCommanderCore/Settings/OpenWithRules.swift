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

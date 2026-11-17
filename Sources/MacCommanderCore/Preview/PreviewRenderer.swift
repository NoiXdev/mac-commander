import Foundation

public struct RenderedPreview: Sendable, Equatable {
    /// The full HTML document.
    public let html: String
    /// The raw text, for the Source toggle (nil if the renderer has none).
    public let source: String?
    /// `mcpreview://` URL of the file's folder (ends in "/"), also used as the document's `<base>`.
    public let baseURL: URL

    public init(html: String, source: String?, baseURL: URL) {
        self.html = html
        self.source = source
        self.baseURL = baseURL
    }
}

public enum PreviewError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int64)
    case unreadable(String)
}

public protocol PreviewRenderer: Sendable {
    var id: String { get }
    /// Cheap: extension / UTType only, no file system access.
    func canRender(_ file: URL) -> Bool
    func render(_ file: URL) async throws(PreviewError) -> RenderedPreview
}

public struct PreviewRegistry: Sendable {
    public static let standard = PreviewRegistry([MarkdownPreviewRenderer()])

    private let renderers: [any PreviewRenderer]

    public init(_ renderers: [any PreviewRenderer]) {
        self.renderers = renderers
    }

    /// The first renderer that accepts `file`; nil means "use Quick Look".
    public func renderer(for file: URL) -> (any PreviewRenderer)? {
        renderers.first { $0.canRender(file) }
    }
}

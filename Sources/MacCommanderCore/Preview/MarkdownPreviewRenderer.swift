import Foundation
import UniformTypeIdentifiers

public struct MarkdownPreviewRenderer: PreviewRenderer {
    public static let maxBytes: Int64 = 5_000_000
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    static let csp =
        "default-src 'none'; img-src mcpreview: https: data:; style-src 'unsafe-inline'; font-src mcpreview: data:"

    public init() {}

    public var id: String { "markdown" }

    public static func isMarkdown(_ url: URL) -> Bool {
        // A folder or package that happens to be called "x.md" is never Markdown (only when the URL
        // already says so; no file system access here).
        if url.hasDirectoryPath { return false }
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
            let markdown = UTType("net.daringfireball.markdown")
        else { return false }
        return type.conforms(to: markdown)
    }

    public func canRender(_ file: URL) -> Bool { Self.isMarkdown(file) }

    public func render(_ file: URL) async throws(PreviewError) -> RenderedPreview {
        let source = try await Self.readSource(file, failIfTooLarge: true)
        let base = PreviewResourceURL.url(forPath: Self.folderPath(of: file))
        let html = await Self.makeDocument(source: source, base: base)
        return RenderedPreview(html: html, source: source, baseURL: base)
    }

    /// The raw text (first 5 MB, "… (truncated)" appended when cut) — also used by "Show Source" for too-large files.
    public static func sourceText(of file: URL) async throws(PreviewError) -> String {
        try await readSource(file, failIfTooLarge: false)
    }

    // MARK: - Internals

    private static func folderPath(of file: URL) -> String {
        let folder = file.standardizedFileURL.deletingLastPathComponent().path
        return folder.hasSuffix("/") ? folder : folder + "/"
    }

    @concurrent
    private static func makeDocument(source: String, base: URL) async -> String {
        let body = MarkdownHTML.body(for: source)
        return """
            <!doctype html><html><head><meta charset="utf-8">\
            <meta http-equiv="Content-Security-Policy" content="\(MarkdownHTML.escape(csp))">\
            <base href="\(MarkdownHTML.escape(base.absoluteString))">\
            <style>\(PreviewStyle.css)</style>\
            </head><body><article class="markdown-body">\(body)</article></body></html>
            """
    }

    @concurrent
    private static func readSource(_ file: URL, failIfTooLarge: Bool) async throws(PreviewError) -> String {
        let size: Int64
        // Symlinks are followed: the regular-file and size checks apply to the target.
        let file = file.resolvingSymlinksInPath()
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw PreviewError.unreadable(
                    L10n.format("preview.error.notRegularFile", "“%@” is not a regular file.", file.lastPathComponent))
            }
            size = Int64(values.fileSize ?? 0)
            if failIfTooLarge && size > maxBytes { throw PreviewError.tooLarge(bytes: size) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            // Only the first 5 MB are ever read, however large the file is.
            let data = try handle.read(upToCount: Int(maxBytes)) ?? Data()
            let truncated = size > maxBytes
            var text = decode(data, truncatedAtEnd: truncated)
            if truncated { text += "\n… (truncated)" }
            return text
        } catch let error as PreviewError {
            throw error
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }

    /// Decoding order: UTF-8 (BOM stripped; when the data was cut mid-file, up to 3 trailing bytes of a
    /// split character are dropped), then UTF-16 when it has a BOM (same trailing trim, up to 3 bytes), then Windows-1252, then ISO Latin-1,
    /// which accepts every byte sequence.
    static func decode(_ data: Data, truncatedAtEnd: Bool = false) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if truncatedAtEnd {
            for cut in 1...3 where bytes.count > cut {
                if let s = String(data: bytes.dropLast(cut), encoding: .utf8) { return s }
            }
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            // When cut, the end may split a code unit (odd length) or a surrogate pair: drop up to 3 bytes.
            for cut in 0...(truncatedAtEnd ? 3 : 0) where data.count > cut {
                if let s = String(data: data.dropLast(cut), encoding: .utf16) { return s }
            }
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

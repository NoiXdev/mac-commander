import AppKit
import Foundation

/// "PDF (simple layout)": loads a document with the macOS text system and lays it out page by page into a PDF.
/// Text, fonts, simple tables and inline images survive; floating images, headers/footers and columns don't.
@MainActor public enum DocumentPDFRenderer {
    /// 2 cm in points.
    static let margin: CGFloat = 72 * 2 / 2.54

    /// The text system's document type for a source extension; nil lets the loader detect it.
    nonisolated static func documentType(forExtension ext: String) -> NSAttributedString.DocumentType? {
        switch ext.lowercased() {
        case "txt": .plain
        case "rtf": .rtf
        case "html", "htm": .html
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "odt": .openDocument
        default: nil
        }
    }

    /// The document's bytes (read by the caller, off the main thread) → NSAttributedString (no remote
    /// resources) → paginated PDF data at the default paper size, 2 cm margins. The caller writes the result.
    /// Loading passes no `.webPreferences`: without it the HTML importer fetches no network resources
    /// (checked on macOS 27; passing WebPreferences re-enables loading), and without a base URL relative
    /// references don't resolve either. A password-protected or unreadable document throws the loader's error.
    public static func render(_ document: Data, fileExtension: String) throws -> Data {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type = documentType(forExtension: fileExtension) { options[.documentType] = type }
        if fileExtension.lowercased() == "txt", String(data: document, encoding: .utf8) != nil {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let text = try NSAttributedString(data: document, options: options, documentAttributes: nil)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let paper = NSPrintInfo.shared.paperSize
        let frame = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        var mediaBox = CGRect(origin: .zero, size: paper)
        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        NSGraphicsContext.current = graphics

        // One text container per page; stop when every glyph is placed (an empty document gets one blank page).
        var placed = 0
        repeat {
            let container = NSTextContainer(size: frame)
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            context.beginPDFPage(nil)
            context.saveGState()
            // AppKit text draws top-down: flip the page.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
            // A glyph too large for any page would never be placed; stop instead of looping forever.
            if range.length == 0 { break }
            placed = NSMaxRange(range)
        } while placed < layout.numberOfGlyphs
        context.closePDF()
        return pdf as Data
    }
}

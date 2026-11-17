import Foundation
import Markdown

/// Renders Markdown to an HTML body fragment. Unlike swift-markdown's `HTMLFormatter` this escapes
/// text, code and attribute values; only raw HTML blocks/inlines pass through (like GitHub).
public enum MarkdownHTML {
    /// The HTML body for `markdown` (no <html>/<head>). Text, code and attribute values are HTML-escaped;
    /// raw HTML blocks/inlines pass through unchanged.
    public static func body(for markdown: String) -> String {
        let document = Document(parsing: markdown)
        var renderer = Renderer()
        renderer.visit(document)
        return renderer.out
    }

    /// GitHub-style heading anchor: lowercase, spaces → "-", drop characters other than letters, digits,
    /// "-" and "_"; duplicates in one document get "-1", "-2", …
    static func slug(_ heading: String, used: inout [String: Int]) -> String {
        var base = ""
        for ch in heading.lowercased() {
            if ch == " " { base.append("-") }
            else if ch == "-" || ch == "_" || ch.isLetter || ch.isNumber { base.append(ch) }
        }
        if let n = used[base] {
            used[base] = n + 1
            return "\(base)-\(n)"
        }
        used[base] = 1
        return base
    }

    static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "'": r += "&#39;"
            default: r.unicodeScalars.append(ch)
            }
        }
        return r
    }

    /// Plain text of a node (for heading slugs and image alt text).
    static func plainText(_ node: Markup) -> String {
        switch node {
        case let t as Text: return t.string
        case let c as InlineCode: return c.code
        case is SoftBreak, is LineBreak: return " "
        case let i as Image: return plainText(children: i)
        default: return plainText(children: node)
        }
    }

    private static func plainText(children node: Markup) -> String {
        var s = ""
        for c in node.children { s += plainText(c) }
        return s
    }

    // Matches bare URLs; trailing punctuation is trimmed afterwards.
    private static let urlRegex = try? NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<]+"#)

    /// Escaped text with bare URLs turned into links.
    static func autolinked(_ text: String) -> String {
        guard text.contains("http") || text.contains("www."), let regex = urlRegex else { return escape(text) }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = m.range
            var url = ns.substring(with: range)
            while let c = url.last, ".,:;!?)".contains(c) {
                url.removeLast()
                range.length -= (c.utf16.count)
            }
            if url.hasSuffix("://") || url == "www." || range.length == 0 { continue }
            out += escape(ns.substring(with: NSRange(location: last, length: range.location - last)))
            let href = url.hasPrefix("www.") ? "http://" + url : url
            out += "<a href=\"\(escape(href))\">\(escape(url))</a>"
            last = range.location + range.length
        }
        out += escape(ns.substring(from: last))
        return out
    }

    /// Tight vs loose lists: swift-markdown doesn't expose it, so a list is loose when a blank line
    /// separates items or blocks inside an item (compared via source ranges). Without ranges: loose.
    /// Last line a node occupies; a range ending at column 1 of a later line has swallowed the trailing newline.
    private static func lastLine(_ node: Markup) -> Int? {
        guard let r = node.range else { return nil }
        let e = r.upperBound
        return (e.column == 1 && e.line > r.lowerBound.line) ? e.line - 1 : e.line
    }

    static func isTight(_ list: Markup) -> Bool {
        var prev: Markup?
        for item in list.children {
            if let p = prev {
                guard let a = lastLine(p), let b = item.range?.lowerBound.line else { return false }
                if b - a > 1 { return false }
            }
            prev = item
            var prevBlock: Markup?
            for block in item.children {
                if let pb = prevBlock {
                    guard let a = lastLine(pb), let b = block.range?.lowerBound.line else { return false }
                    if b - a > 1 { return false }
                }
                prevBlock = block
            }
        }
        return true
    }

    private struct Renderer: MarkupVisitor {
        typealias Result = Void
        var out = ""
        var used: [String: Int] = [:]
        var tightStack: [Bool] = []
        var alignments: [Table.ColumnAlignment?] = []

        mutating func descend(_ node: Markup) {
            for c in node.children { visit(c) }
        }

        /// Unknown/unsupported nodes: render children, or the escaped source text for leaves.
        mutating func defaultVisit(_ markup: Markup) {
            if markup.childCount > 0 { descend(markup) } else { out += MarkdownHTML.escape(markup.format()) }
        }

        mutating func visitText(_ text: Text) {
            out += MarkdownHTML.autolinked(text.string)
        }

        mutating func visitParagraph(_ p: Paragraph) {
            if p.parent is ListItem, tightStack.last == true {
                descend(p)
                out += "\n"
            } else {
                out += "<p>"; descend(p); out += "</p>\n"
            }
        }

        mutating func visitHeading(_ h: Heading) {
            let id = MarkdownHTML.slug(MarkdownHTML.plainText(h), used: &used)
            let level = min(max(h.level, 1), 6)
            out += "<h\(level) id=\"\(MarkdownHTML.escape(id))\">"; descend(h); out += "</h\(level)>\n"
        }

        mutating func visitCodeBlock(_ c: CodeBlock) {
            if let lang = c.language, !lang.isEmpty {
                out += "<pre><code class=\"language-\(MarkdownHTML.escape(lang))\">"
            } else {
                out += "<pre><code>"
            }
            out += MarkdownHTML.escape(c.code) + "</code></pre>\n"
        }

        mutating func visitInlineCode(_ c: InlineCode) {
            out += "<code>\(MarkdownHTML.escape(c.code))</code>"
        }

        mutating func visitEmphasis(_ e: Emphasis) { out += "<em>"; descend(e); out += "</em>" }
        mutating func visitStrong(_ s: Strong) { out += "<strong>"; descend(s); out += "</strong>" }
        mutating func visitStrikethrough(_ s: Strikethrough) { out += "<del>"; descend(s); out += "</del>" }
        mutating func visitBlockQuote(_ b: BlockQuote) { out += "<blockquote>\n"; descend(b); out += "</blockquote>\n" }
        mutating func visitThematicBreak(_ t: ThematicBreak) { out += "<hr>\n" }
        mutating func visitLineBreak(_ l: LineBreak) { out += "<br>\n" }
        mutating func visitSoftBreak(_ s: SoftBreak) { out += "\n" }
        mutating func visitHTMLBlock(_ h: HTMLBlock) { out += h.rawHTML }
        mutating func visitInlineHTML(_ h: InlineHTML) { out += h.rawHTML }

        mutating func visitLink(_ l: Link) {
            out += "<a href=\"\(MarkdownHTML.escape(l.destination ?? ""))\""
            if let t = l.title, !t.isEmpty { out += " title=\"\(MarkdownHTML.escape(t))\"" }
            out += ">"; descend(l); out += "</a>"
        }

        mutating func visitImage(_ i: Image) {
            out += "<img src=\"\(MarkdownHTML.escape(i.source ?? ""))\" alt=\"\(MarkdownHTML.escape(MarkdownHTML.plainText(i)))\""
            if let t = i.title, !t.isEmpty { out += " title=\"\(MarkdownHTML.escape(t))\"" }
            out += ">"
        }

        mutating func visitUnorderedList(_ l: UnorderedList) {
            tightStack.append(MarkdownHTML.isTight(l))
            out += "<ul>\n"; descend(l); out += "</ul>\n"
            tightStack.removeLast()
        }

        mutating func visitOrderedList(_ l: OrderedList) {
            tightStack.append(MarkdownHTML.isTight(l))
            out += l.startIndex != 1 ? "<ol start=\"\(l.startIndex)\">\n" : "<ol>\n"
            descend(l); out += "</ol>\n"
            tightStack.removeLast()
        }

        mutating func visitListItem(_ item: ListItem) {
            if let cb = item.checkbox {
                out += "<li class=\"task\"><input type=\"checkbox\" disabled\(cb == .checked ? " checked" : "")> "
            } else {
                out += "<li>"
            }
            descend(item); out += "</li>\n"
        }

        mutating func visitTable(_ t: Table) {
            alignments = t.columnAlignments
            out += "<table>\n"
            descend(t)
            out += "</table>\n"
            alignments = []
        }

        mutating func visitTableHead(_ h: Table.Head) {
            out += "<thead><tr>"
            cells(h, tag: "th")
            out += "</tr></thead>\n"
        }

        mutating func visitTableBody(_ b: Table.Body) {
            guard b.childCount > 0 else { return }
            out += "<tbody>\n"; descend(b); out += "</tbody>\n"
        }

        mutating func visitTableRow(_ r: Table.Row) {
            out += "<tr>"; cells(r, tag: "td"); out += "</tr>\n"
        }

        private mutating func cells(_ row: Markup, tag: String) {
            var col = 0
            for case let cell as Table.Cell in row.children {
                defer { col += 1 }
                guard cell.colspan > 0, cell.rowspan > 0 else { continue }
                out += "<\(tag)"
                if col < alignments.count, let a = alignments[col] {
                    let v: String
                    switch a {
                    case .left: v = "left"
                    case .center: v = "center"
                    case .right: v = "right"
                    }
                    out += " style=\"text-align:\(v)\""
                }
                if cell.colspan > 1 { out += " colspan=\"\(cell.colspan)\"" }
                if cell.rowspan > 1 { out += " rowspan=\"\(cell.rowspan)\"" }
                out += ">"; descend(cell); out += "</\(tag)>"
            }
        }
    }
}

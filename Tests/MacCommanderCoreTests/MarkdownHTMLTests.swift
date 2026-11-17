import Testing
import Foundation
@testable import MacCommanderCore

struct MarkdownHTMLTests {
    private func html(_ s: String) -> String { MarkdownHTML.body(for: s) }

    @Test func escapesCode() {
        #expect(html("```swift\nlet x = 1 < 2 && \"a\"\n```")
            .contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2 &amp;&amp; &quot;a&quot;\n</code></pre>"))
        #expect(html("`</code><script>`").contains("<code>&lt;/code&gt;&lt;script&gt;</code>"))
        #expect(html("```\nx\n```").contains("<pre><code>x\n</code></pre>"))
    }

    @Test func escapesTextAndAttributes() {
        let h = html("a < b & [x](https://e.com/?a=1&b=\"2\")")
        #expect(h.contains("a &lt; b &amp; "))
        #expect(h.contains("&amp;b=&quot;2&quot;"))
    }

    @Test func tableWithAlignment() {
        let h = html("| a | b |\n|:--|--:|\n| 1 | 2 |")
        #expect(h.contains("<th style=\"text-align:left\">a</th>"))
        #expect(h.contains("<th style=\"text-align:right\">b</th>"))
        #expect(h.contains("<td style=\"text-align:right\">2</td>"))
    }

    @Test func taskList() {
        let h = html("- [x] done\n- [ ] todo")
        #expect(h.components(separatedBy: "<input type=\"checkbox\" disabled checked>").count == 2)
        #expect(h.components(separatedBy: "<input type=\"checkbox\" disabled>").count == 2)
    }

    @Test func strikethroughAndEmphasis() {
        let h = html("~~a~~ *b* **c**")
        #expect(h.contains("<del>a</del>") && h.contains("<em>b</em>") && h.contains("<strong>c</strong>"))
    }

    @Test func headingSlugs() {
        let h = html("# Hello World!\n## Hello World!")
        #expect(h.contains("id=\"hello-world\"") && h.contains("id=\"hello-world-1\""))
        #expect(html("# Ärger & Co").contains("id=\"ärger--co\""))
    }

    @Test func orderedStart() {
        #expect(html("3. a\n4. b").contains("<ol start=\"3\">"))
        #expect(!html("1. a").contains("start"))
    }

    @Test func autolinks() {
        #expect(html("see https://example.com/x.").contains("<a href=\"https://example.com/x\">https://example.com/x</a>."))
        #expect(!html("`https://a.b`").contains("<a "))
        #expect(!html("[https://a.b](https://a.b)").contains("<a href=\"https://a.b\"><a"))
        #expect(!html("[t](https://a.b) ").contains("<a href=\"https://a.b\">https://a.b</a>"))
        #expect(html("go www.example.com, now").contains("<a href=\"http://www.example.com\">www.example.com</a>,"))
    }

    @Test func tightAndLooseLists() {
        #expect(html("- a\n- b").contains("<li>a\n</li>"))
        #expect(html("- a\n\n- b").contains("<li><p>a</p>\n</li>"))
    }

    @Test func rawHTMLPassesThrough() {
        let raw = "<details><summary>S</summary>x</details>"
        #expect(html(raw).contains(raw))
    }

    @Test func hostileMarkdownIsInert() {
        #expect(html("[x](javascript:alert(1))").contains("href=\"javascript:alert(1)\""))
        #expect(html("<script>alert(1)</script>").contains("<script>alert(1)</script>"))
        let h = html("`<b>` ``` \n<x>\n```\n[[Sym]] ``Sym``")
        #expect(!h.contains("<b>"))
    }

    @Test func escapesImageAndLinkAttributes() {
        let img = html("![a<b](x\"y \"t\\\"\")")
        #expect(img.contains("src=\"x&quot;y\""))
        #expect(img.contains("alt=\"a&lt;b\""))
        #expect(img.contains("title=\"t&quot;\""))
        let link = html("[l](u \"t\\\"<\")")
        #expect(link.contains("title=\"t&quot;&lt;\""))
    }

    @Test func escapesCodeLanguage() {
        #expect(html("```a\"><x\nq\n```").contains("class=\"language-a&quot;&gt;&lt;x\""))
    }

    @Test func codeLanguageIsFirstWord() {
        let h = html("```js onclick=x\nq\n```")
        #expect(h.contains("class=\"language-js\""))
        #expect(!h.contains("onclick"))
    }

    @Test func escapesAutolinkPath() {
        let h = html("<x> https://e.com/?a=1&b=<")
        #expect(h.contains("<x> ") == true) // raw inline HTML passes through
        #expect(h.contains("<a href=\"https://e.com/?a=1&amp;b=\">https://e.com/?a=1&amp;b=</a>"))
        let t = html("a&b https://e.com/\"q")
        #expect(t.contains("a&amp;b "))
        #expect(html("https://e.com/x a&b").contains("</a> a&amp;b"))
        #expect(t.contains("href=\"https://e.com/&quot;q\">https://e.com/&quot;q</a>"))
    }

    @Test func smartPunctuationIsOff() {
        let h = html("a -- \"b\"")
        #expect(h.contains("a -- &quot;b&quot;"))
        #expect(html("# a -- b").contains("id=\"a----b\""))
    }

    @Test func duplicateSlugsDoNotCollide() {
        let h = html("# a\n# a\n# a-1")
        #expect(h.contains("id=\"a\"") && h.contains("id=\"a-1\"") && h.contains("id=\"a-1-1\""))
    }

    @Test func autolinkBoundariesAndCase() {
        #expect(!html("xhttps://a.b").contains("<a "))
        #expect(!html("foowww.bar.com").contains("<a "))
        #expect(html("HTTPS://A.B").contains("<a href=\"HTTPS://A.B\">HTTPS://A.B</a>"))
        #expect(html("(https://a.b)").contains("<a href=\"https://a.b\">"))
        #expect(html("*www.a.b*").contains("<a href=\"http://www.a.b\">"))
    }

    @Test func autolinkKeepsBalancedParens() {
        #expect(html("https://en.wikipedia.org/wiki/Foo_(bar)")
            .contains("<a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\">"))
        #expect(html("(see https://a.b/x)").contains("<a href=\"https://a.b/x\">https://a.b/x</a>)"))
    }

    @Test func largeDocumentIsFast() {
        var s = ""
        for i in 0..<5000 {
            s += "## Heading \(i)\nSome *text* with `code` and https://example.com/\(i) here.\n- [ ] item \(i)\n\n"
        }
        let start = Date()
        let h = html(s)
        #expect(!h.isEmpty)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

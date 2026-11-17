/// The stylesheet embedded in every rendered preview document (no SwiftPM resources, so a Swift constant).
enum PreviewStyle {
    static let css = """
        :root { color-scheme: light dark; }
        html { -webkit-text-size-adjust: 100%; }
        body {
          margin: 0; background: #fff; color: #1f2328;
          font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        }
        .markdown-body { max-width: none; padding: 16px; word-wrap: break-word; }
        .markdown-body > :first-child { margin-top: 0; }
        .markdown-body > :last-child { margin-bottom: 0; }
        a { color: -apple-system-blue; text-decoration: none; }
        a:hover { text-decoration: underline; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid #d1d9e0; }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid #d1d9e0; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: .875em; }
        h6 { font-size: .85em; color: #59636e; }
        p, ul, ol, blockquote, pre, table, details { margin: 0 0 16px; }
        ul, ol { padding-left: 2em; }
        li + li { margin-top: .25em; }
        li > p { margin-top: 16px; }
        li.task-list-item, li:has(> input[type="checkbox"]) { list-style: none; }
        li > input[type="checkbox"] { margin: 0 .35em .25em -1.4em; vertical-align: middle; }
        ul:has(> li > input[type="checkbox"]) { padding-left: 1.5em; }
        blockquote { padding: 0 1em; color: #59636e; border-left: .25em solid #d1d9e0; }
        blockquote > :last-child { margin-bottom: 0; }
        hr { height: .25em; padding: 0; margin: 24px 0; background: #d1d9e0; border: 0; }
        img { max-width: 100%; box-sizing: border-box; }
        code, pre, kbd, tt {
          font: 85% ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        code { padding: .2em .4em; background: rgba(129, 139, 152, .18); border-radius: 6px; }
        pre {
          padding: 16px; overflow-x: auto; line-height: 1.45;
          background: #f6f8fa; border-radius: 6px;
        }
        pre code { padding: 0; background: transparent; border-radius: 0; white-space: pre; }
        table { display: block; width: max-content; max-width: 100%; overflow: auto; border-spacing: 0; border-collapse: collapse; }
        th, td { padding: 6px 13px; border: 1px solid #d1d9e0; }
        th { font-weight: 600; }
        tr { background: #fff; border-top: 1px solid #d1d9e0; }
        tr:nth-child(2n) { background: #f6f8fa; }
        del { opacity: .7; }
        @media (prefers-color-scheme: dark) {
          body { background: #1e1e1e; color: #e6edf3; }
          h1, h2 { border-bottom-color: #3d444d; }
          h6, blockquote { color: #9198a1; }
          blockquote { border-left-color: #3d444d; }
          hr { background: #3d444d; }
          code { background: rgba(110, 118, 129, .4); }
          pre { background: #2b2b2b; }
          th, td, tr { border-color: #3d444d; }
          tr { background: #1e1e1e; }
          tr:nth-child(2n) { background: #272727; }
        }
        """
}

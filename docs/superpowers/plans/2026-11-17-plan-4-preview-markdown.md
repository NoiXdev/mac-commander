# MacCommander Plan 4: Preview Panel and Markdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A preview panel on the right side of the window that the user toggles with ⇧⌘P.
- It shows the selected item.
- Markdown files are rendered GitHub-style: headings, lists, tables, code blocks, task lists, links, and images relative to the file. The rendering follows light/dark mode and has a Rendered/Source toggle.
- Everything else uses the system Quick Look view inside the panel.
- Renderers are pluggable, so code, JSON or CSV renderers can be added later.

**Architecture:**
- **Core:**
  - Owns a small preview framework: the `PreviewRenderer` protocol plus a `PreviewRegistry` (first match wins), with Quick Look as the fallback.
  - The Markdown renderer parses with Apple's `swift-markdown` (cmark-gfm). It produces HTML through **our own escaping `MarkupVisitor`**: the library's `HTMLFormatter` doesn't escape code blocks (checked: `1 < 2` comes out raw).
  - The HTML is a full document with an embedded GitHub-like stylesheet, a strict Content-Security-Policy and a `<base>` pointing at the file's folder through an `mcpreview://` URL.
- **UI:**
  - The window's detail area becomes an `HSplitView` holding the file list and a `PreviewPane`.
  - The pane debounces selection changes and shows a placeholder, a `QLPreviewView`, or a `WKWebView`.
  - The web view has JavaScript off and an `mcpreview` scheme handler that serves local files off the main thread. Its navigation policy opens web links in the browser and reveals local links in MacCommander.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WebKit (`WKWebView`, `WKURLSchemeHandler`), Quartz (`QLPreviewView`), `swift-markdown` 0.9.x (Apache-2.0, pulls in `swift-cmark`), Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md` (§2.2.4 Better previews, §7 "Markdown", §4 sluggishness).

### Roadmap position
Plan 4 of 6. Plans 1–3 are done. Next: Plan 5 (network shares), Plan 6 (tags, search, iCloud, Settings, icon).

## Global Constraints
- **Toolchain:** macOS 15, Swift 6, CLT-only.
  - Run tests with `scripts/test.sh` and use Swift Testing.
  - No `@State`/`@Entry` macros: use `State<T>` properties and hand-written keys, as the existing code does.
  - The build must still work with `scripts/build-app.sh`. Dependencies link statically into the binary, and no SwiftPM resource bundles are used: CSS and templates live in Swift source as string constants.
- **New dependency:** `https://github.com/swiftlang/swift-markdown.git`, `.upToNextMinor(from: "0.9.0")`, product `Markdown`, used by `MacCommanderCore` only. Commit `Package.resolved`. Add `THIRD-PARTY-NOTICES.md` with swift-markdown's and swift-cmark's licenses: Apache-2.0, with the BSD-2-Clause cmark notice.
- **Markdown files** are recognized by the extensions `md, markdown, mdown, mkd, mkdn` (case-insensitive), or by a UTType conforming to `net.daringfireball.markdown`.
- **Web view security:**
  - JavaScript disabled (`WKWebpagePreferences.allowsContentJavaScript = false`).
  - The document carries `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src mcpreview: https: data:; style-src 'unsafe-inline'; font-src mcpreview: data:">`.
  - Link clicks never navigate the web view except to `#anchors`. `http`, `https` and `mailto` open in the default app. Local links (relative or `file:`/`mcpreview:`) reveal the target in the window. Every other scheme, `javascript:` included, is ignored.
  - Raw HTML in Markdown passes through, as on GitHub, but can't run scripts.
- **Main thread:** no file reads or Markdown parsing on it. Rendering runs `@concurrent`, and the scheme handler reads files off the main thread.
- **Size limit:** Markdown files larger than **5 MB** are not rendered. The panel shows `“x.md” is too large to render (12 MB).` with a "Show Source" button instead. Source view is capped at the first 5 MB, with a final line `… (truncated)`.
- **Persistent state:**
  - The panel's visibility and the Markdown Rendered/Source choice are global view settings in `ViewSettings` (`showPreview: Bool = false`, `markdownShowsSource: Bool = false`). They are decoded leniently per field, like the existing keys.
  - Nothing changes on its own (spec §2.2.1 spirit).
- **Wording:** UI strings in English via `String(localized:)`.
- **Commits:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on `main`, without worktrees.

## Review Focus
1. **Hostile Markdown never runs code or navigates the panel away.** Cases: `<script>`, `<img onerror=…>`, `[x](javascript:alert(1))`, `<iframe src=…>`, `<meta http-equiv=refresh>`. Pinned in Task 2 (output) and Task 5 (web view settings and policy).
2. **Code spans and code blocks containing `<`, `&`, `</code>` or `<script>` render literally.** Pinned in Task 2.
3. **A huge, binary or non-UTF-8 `.md` file** gets a size message or decodes with a fallback encoding, never hangs or crashes. Pinned in Task 3.
4. **Arrowing quickly through 1,000 files** never shows the preview of a file other than the selected one, and the list stays responsive. Pinned in Task 4: debounce plus a generation check.
5. **Relative images** with spaces, umlauts or `../` in the path display correctly, and nothing in the file system outside a plain read is touched. Pinned in Task 3 (URL mapping) and Task 5 (handler).

---

## File Structure

```
Package.swift, Package.resolved              + swift-markdown (Task 1)
THIRD-PARTY-NOTICES.md                       licenses (Task 1)
Sources/MacCommanderCore/
  Preview/MarkdownHTML.swift                 escaping MarkupVisitor → HTML body (Task 2)
  Preview/PreviewRenderer.swift              protocol, RenderedPreview, PreviewRegistry (Task 3)
  Preview/MarkdownPreviewRenderer.swift      file → full HTML document (Task 3)
  Preview/PreviewStyle.swift                 GitHub-like CSS (light/dark) as a string (Task 3)
  Preview/PreviewResourceURL.swift           file path ⇄ mcpreview:// URL (Task 3)
  Settings/ViewSettings.swift                + showPreview, markdownShowsSource (Task 3)
  Browser/BrowserModel.swift                 + reveal(_:) (Task 5)
Sources/MacCommander/
  Preview/PreviewPane.swift                  panel: header, placeholders, content switch (Task 4)
  Preview/PreviewController.swift            @MainActor @Observable: selection → content, debounce (Task 4)
  Preview/QuickLookPreview.swift             NSViewRepresentable QLPreviewView (Task 4)
  Preview/MarkdownWebView.swift              WKWebView, scheme handler, policy, toggle (Task 5)
  Browser/BrowserWindow.swift, App/BrowserCommands.swift   HSplitView + ⇧⌘P (Task 4)
Tests/MacCommanderCoreTests/
  MarkdownHTMLTests, PreviewRendererTests, PreviewResourceURLTests, ViewSettingsStoreTests, BrowserModelTests
```

---

### Task 1: Add swift-markdown

**Files:** Modify `Package.swift`. Create `Package.resolved` (generated) and `THIRD-PARTY-NOTICES.md`. Create a temporary `Tests/MacCommanderCoreTests/MarkdownDependencyTests.swift`, which stays in the repo as a smoke test.

- [ ] **Step 1:** Add the dependency (Global Constraints) and add `.product(name: "Markdown", package: "swift-markdown")` to `MacCommanderCore` only.
- [ ] **Step 2: Smoke test.** `@Test func parsesGitHubTable()`: `Document(parsing: "| a | b |\n|---|:-:|\n| 1 | 2 |")` has a `Table` child whose `columnAlignments == [nil, .center]`.
- [ ] **Step 3: Run** `scripts/test.sh` (it resolves, builds and passes), then `scripts/build-app.sh`, which builds and launches unchanged. `otool -L build/MacCommander.app/Contents/MacOS/MacCommander` must show no non-system dylibs.
- [ ] **Step 4:** Write `THIRD-PARTY-NOTICES.md`. It holds swift-markdown's Apache-2.0 notice, swift-cmark's license text from its `COPYING`, and the URLs.
- [ ] **Step 5: Commit** `build: add swift-markdown for Markdown previews`

---

### Task 2: `MarkdownHTML`, the escaping HTML renderer

**Files:** Create `Sources/MacCommanderCore/Preview/MarkdownHTML.swift` and `Tests/MacCommanderCoreTests/MarkdownHTMLTests.swift`.

**Interfaces:**
```swift
public enum MarkdownHTML {
    /// The HTML body for `markdown` (no <html>/<head>). Text, code and attribute values are HTML-escaped;
    /// raw HTML blocks/inlines pass through unchanged.
    public static func body(for markdown: String) -> String
    /// GitHub-style heading anchor: lowercase, spaces → "-", drop characters other than letters, digits, "-" and "_";
    /// duplicates in one document get "-1", "-2", …
    static func slug(_ heading: String, used: inout [String: Int]) -> String
}
```
**Rendering rules** (a `MarkupVisitor` that produces a String):
- **Headings:** `<h1 id="slug">…</h1>`.
- **Code blocks:** `<pre><code class="language-x">ESCAPED</code></pre>`. Omit the `class` when there's no language. The language itself is escaped too.
- **Inline code:** `<code>ESCAPED</code>`.
- **Emphasis:** `<em>`, `<strong>`, and `<del>` for strikethrough.
- **Tables:** `<table><thead><tr><th style="text-align:center">…`. Body cells get the same alignment.
- **Lists:** `<ul>` and `<ol start="n">`, with `start` only when n ≠ 1.
- **Task items:** `<li class="task"><input type="checkbox" disabled checked> …</li>`, with `checked` only when done.
  - **Tight lists** (`ListItem` children that are single paragraphs with no blank-line separation, which swift-markdown exposes through the paragraph structure) render paragraph content without `<p>` wrapping.
  - When in doubt, wrap in `<p>`. Visual difference only.
- **Links:** `<a href="ESCAPED">…</a>`, with an optional `title`.
- **Images:** `<img src="ESCAPED" alt="ESCAPED-plain-text">`.
- **Block quotes, thematic breaks, line breaks:** `<blockquote>`, `<hr>`, and `<br>` for hard breaks. Soft breaks become `"\n"`.
- **Raw HTML:** `HTMLBlock` and `InlineHTML` pass through as-is.
- **Bare URLs in text:** `https?://…` and `www.…` inside text nodes become links, as in GitHub autolink. This happens only outside links and code. Trailing `.,:;!?)` stays outside the link.
- **Escaping:** `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`.

- [ ] **Step 1: Write the failing tests** (`#expect(html.contains(…))` or exact equality for small inputs):
  - `escapesCode`: ```` ```swift\nlet x = 1 < 2 && "a"\n``` ```` gives `<pre><code class="language-swift">let x = 1 &lt; 2 &amp;&amp; &quot;a&quot;\n</code></pre>`. Also `` `</code><script>` `` gives `<code>&lt;/code&gt;&lt;script&gt;</code>`.
  - `escapesTextAndAttributes`: `a < b & [x](https://e.com/?a=1&b="2")` escapes the text, and the href contains `&amp;b=&quot;2&quot;`.
  - `tableWithAlignment`: `| a | b |\n|:--|--:|\n| 1 | 2 |` gives `<th style="text-align:left">a</th>`, `<th style="text-align:right">b</th>` and `<td style="text-align:right">2</td>`.
  - `taskList`: `- [x] done\n- [ ] todo` gives `<input type="checkbox" disabled checked>` once and `<input type="checkbox" disabled>` once.
  - `strikethroughAndEmphasis`: `~~a~~ *b* **c**` gives `<del>a</del>`, `<em>b</em>`, `<strong>c</strong>`.
  - `headingSlugs`: `# Hello World!\n## Hello World!` gives `id="hello-world"` and `id="hello-world-1"`. `# Ärger & Co` gives `id="ärger--co"`.
  - `orderedStart`: `3. a\n4. b` gives `<ol start="3">`.
  - `autolinks`: `see https://example.com/x.` gives `<a href="https://example.com/x">https://example.com/x</a>.`. Inside `` `https://a.b` `` there is no link.
  - `rawHTMLPassesThrough`: `<details><summary>S</summary>x</details>` is kept verbatim.
  - `hostileMarkdownIsInert` asserts on the output only; Task 5 makes it inert in the web view:
    - `[x](javascript:alert(1))` gives `href="javascript:alert(1)"`, escaped;
    - `<script>alert(1)</script>` passes through, since it's raw HTML;
    - this test just pins that nothing crashes and the output contains no unescaped user text outside raw HTML.
  - `largeDocumentIsFast`: 20,000 lines of mixed Markdown render in under 2 s in a debug build.
- [ ] **Step 2: Run** `scripts/test.sh --filter MarkdownHTML`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): GitHub-flavored Markdown to escaped HTML`

---

### Task 3: Preview framework, Markdown document, resource URLs and settings

**Files:**
- Create in `Sources/MacCommanderCore/Preview/`: `PreviewRenderer.swift`, `MarkdownPreviewRenderer.swift`, `PreviewStyle.swift`, `PreviewResourceURL.swift`.
- Modify `Settings/ViewSettings.swift`.
- Tests: `PreviewRendererTests.swift`, `PreviewResourceURLTests.swift`, `ViewSettingsStoreTests.swift`.

**Interfaces:**
```swift
public struct RenderedPreview: Sendable, Equatable {
    public let html: String            // full document
    public let source: String?         // the raw text, for the Source toggle (nil if the renderer has none)
    public let baseURL: URL            // mcpreview:// URL of the file's folder
}
public enum PreviewError: Error, Equatable, Sendable { case tooLarge(bytes: Int64), unreadable(String) }
public protocol PreviewRenderer: Sendable {
    var id: String { get }
    func canRender(_ file: URL) -> Bool              // cheap: extension / UTType only, no I/O
    func render(_ file: URL) async throws(PreviewError) -> RenderedPreview
}
public struct PreviewRegistry: Sendable {
    public static let standard: PreviewRegistry       // [MarkdownPreviewRenderer()]
    public init(_ renderers: [any PreviewRenderer])
    public func renderer(for file: URL) -> (any PreviewRenderer)?   // nil → Quick Look
}
public struct MarkdownPreviewRenderer: PreviewRenderer {
    public static let maxBytes: Int64 = 5_000_000
    public static func isMarkdown(_ url: URL) -> Bool
    /// The raw text (first 5 MB, "… (truncated)" appended when cut) — also used by "Show Source" for too-large files.
    public static func sourceText(of file: URL) async throws(PreviewError) -> String
}
public enum PreviewResourceURL {
    public static let scheme = "mcpreview"
    public static func url(for fileURL: URL) -> URL        // mcpreview://local/<percent-encoded absolute path>
    public static func fileURL(for url: URL) -> URL?       // inverse; nil for other schemes/hosts or non-absolute paths
}
```
- **Reading and decoding:** done `@concurrent`. A file over 5 MB (from `fileSizeKey`) throws `.tooLarge`. Decoding tries UTF-8 (a BOM is stripped), then `String(contentsOf:usedEncoding:)`, then ISO Latin-1, which always succeeds.
- **Document:**
  - `<!doctype html><html><head><meta charset="utf-8">`, the CSP from Global Constraints, `<base href="<mcpreview url of folder>/">`, and `<style>PreviewStyle.css</style>`.
  - Then `</head><body><article class="markdown-body">…</article></body></html>`.
- **`PreviewStyle.css`:** GitHub-like: system font, 14 px, max-width none, padding 16 px. It covers tables with borders and zebra rows, code blocks with background and horizontal scroll, `blockquote` with a left border, and task-list checkboxes. It includes `@media (prefers-color-scheme: dark)` overrides, and links use the system accent `-apple-system-blue`.
- **`ViewSettings`:** add `showPreview` and `markdownShowsSource`, both defaulting to false, with lenient `decodeIfPresent`, like the existing fields.

- [ ] **Step 1: Write the failing tests:**
  - `registryPicksMarkdown`: `a.MD` and `b.markdown` give the markdown renderer; `c.txt` and a folder give nil.
  - `rendersDocumentWithBaseAndCSP`: `tmp/My Docs/readme.md` with `# Hi\n![p](pics/ä b.png)` renders HTML containing:
    - `Content-Security-Policy`;
    - `<base href="mcpreview://local/`, where the folder path is percent-encoded and `My%20Docs` is followed by `/`;
    - `<h1 id="hi">Hi</h1>`;
    - `src="pics/ä b.png"` escaped as is (WebKit resolves it against `base`).
    
    `source` equals the file text.
  - `tooLargeThrows`: a sparse 6 MB file (`ftruncate`) throws `.tooLarge(bytes: 6_000_000)`. `sourceText` returns at most 5 MB of content plus `… (truncated)`.
  - `latin1Fallback`: bytes `0x47 0x72 0xFC 0xDF 0x65` ("Grüße" in ISO-8859-1) render as `Grüße`. Invalid UTF-8 doesn't throw.
  - `binaryFileDoesNotHang`: 1 MB of random bytes named `x.md` renders within 3 s, with any content.
  - `resourceURLRoundTrip`: `/Users/a/My Docs/ä b.png` gives an `mcpreview://local/…` URL, and `fileURL(for:)` maps it back to an equal path. A URL whose resolved path contains `..` (`mcpreview://local/Users/a/x/../y.png`) maps to the standardized `/Users/a/y.png`. `https://…` and `mcpreview://other/x` give nil.
  - `viewSettingsDecodeNewKeysLeniently`: old JSON without the new keys decodes with `showPreview == false`, and the existing values are kept.
- [ ] **Step 2: Run** `scripts/test.sh --filter "PreviewRenderer|PreviewResourceURL|ViewSettings"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): pluggable preview renderers, Markdown documents, preview URLs`

---

### Task 4: Preview panel with Quick Look

**Files:**
- Create in `Sources/MacCommander/Preview/`: `PreviewController.swift`, `PreviewPane.swift`, `QuickLookPreview.swift`.
- Modify `Browser/BrowserWindow.swift` and `App/BrowserCommands.swift`.

**Behavior:**
- **Layout:**
  - When `settings.showPreview` is true, the detail column becomes an `HSplitView` holding the file list and `PreviewPane` (min width 240, ideal 360). The path bar and operations strip stay below both, at full width.
  - The menu item View ▸ "Show Preview" / "Hide Preview" (⇧⌘P) and a toolbar button (`sidebar.right`) toggle the setting.
- **`PreviewController`** (`@MainActor @Observable`, one per window) watches `model.selection` and `model.currentURL`. After **150 ms** without changes, it resolves the content:
  - **0 items:** placeholder "No Selection".
  - **2 or more items:** placeholder "<n> items".
  - **A folder or package:** `.quickLook(url)`. QLPreviewView shows the icon and info.
  - **A file where `PreviewRegistry.standard.renderer(for:)` is non-nil:** `.rendered(RenderedPreview)` (Task 5 displays it). Until then, show the source text in a scrolling monospaced `Text` (selectable).
  - **Any other file:** `.quickLook(url)`.
  - **Inside an archive** (`model.archiveLocation != nil`):
    - folders and symlinks show the placeholder "<name>" with the folder icon;
    - files are first extracted with `ArchivePreviewCache.shared.files([inner], of: archive)`, which gives a temporary URL, and then go through the same rules;
    - a password error shows the placeholder "Encrypted. Press Space to enter the password." and never prompts on selection.
  - **Errors:** `PreviewError.tooLarge` shows its message with a "Show Source" button. Other errors show `“<name>” can’t be previewed.`
- **Staleness:** each resolution has a generation number, and a result arrives only if its generation is still current and the selection is unchanged. Rendering runs in a `Task` that is cancelled when superseded.
- **Header:** above the content sits an icon (`NSWorkspace.icon` for real files, UTType for archive entries), then the name, then a line `<Kind> — <size>` (size for files only), then the modification date (`.abbreviated` date and `.shortened` time).
- **`QuickLookPreview`:** an `NSViewRepresentable` around `QLPreviewView(frame:style: .normal)` with `autostarts = true`. `updateNSView` sets `previewItem` only when the URL changed. `dismantleNSView` calls `close()`.
- **When the panel is hidden,** the controller does nothing: no resolution and no extraction.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then by hand:
  1. ⇧⌘P shows and hides the panel. The choice survives a relaunch.
  2. A PDF, an image and a Pages file preview in the panel.
  3. A folder shows its icon.
  4. Two selected items show "2 items".
  5. Holding ↓ through a folder of 1,000 files stays smooth, and the panel ends on the last file.
  6. A `.md` file shows its text (rendering comes in Task 5).
  7. Inside a zip, an image entry previews.
- [ ] **Step 3: Commit** `feat: preview panel with Quick Look (⇧⌘P)`

---

### Task 5: Markdown web view

**Files:**
- Create `Sources/MacCommander/Preview/MarkdownWebView.swift`.
- Modify `Preview/PreviewPane.swift` and `PreviewController.swift`.
- Modify `Sources/MacCommanderCore/Browser/BrowserModel.swift`, with a test in `BrowserModelTests.swift`.

**Interfaces:**
- Core: `BrowserModel.reveal(_ url: URL) async`. It navigates to `url.deletingLastPathComponent()`, unless that's already the current folder, then selects the item spelled as in `items` (reuse `selectAfterOperation`). A missing target beeps in the UI and does nothing in Core.
- UI: `MarkdownWebView` is an `NSViewRepresentable` around `WKWebView`.

**Web view setup:**
- **Configuration:**
  - `defaultWebpagePreferences.allowsContentJavaScript = false`.
  - `setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: "mcpreview")`.
  - `websiteDataStore = .nonPersistent()`.
  - No user scripts.
  - Load with `loadHTMLString(html, baseURL: rendered.baseURL)`.
- **`PreviewSchemeHandler`:**
  - Maps the request to a file with `PreviewResourceURL.fileURL(for:)`.
  - Reads the file off the main thread (`Task.detached`). It serves only regular files (`lstat`, and refuses folders and devices) up to 50 MB, with the MIME type taken from `UTType(filenameExtension:)?.preferredMIMEType`, falling back to `application/octet-stream`.
  - Unknown and failed requests get `didFailWithError`.
  - It tracks running tasks, so `stop` cancels them, and never calls back after `stop`.
- **Navigation policy** (`decidePolicyFor navigationAction`):
  - The initial load (`.other`, while not loaded yet) is allowed.
  - A same-document fragment (`#…` on the same base) is allowed.
  - `http`, `https` and `mailto` are cancelled and opened with `NSWorkspace.shared.open`.
  - `mcpreview` and `file`, and relative links (which resolve to `mcpreview`), are cancelled. They map to a file URL and call `model.reveal`. For a link with `#fragment` to the same file, scroll within the page instead.
  - Anything else is cancelled and ignored.
  - New-window requests (`createWebViewWith`) return nil and apply the same rule to the request.
- **Appearance:** the stylesheet follows the system appearance. The web view's `underPageBackgroundColor = .textBackgroundColor`, and `drawsBackground` is left on.
- **Rendered/Source:** a segmented control (Rendered | Source) appears in the panel header only for rendered previews and is bound to `settings.markdownShowsSource`. Source is a monospaced, selectable `NSTextView` (read-only) showing `rendered.source`.
- **Live update:** while a real file (not an archive entry) is previewed, a `DirectoryWatcher` on the file itself is active. A change re-renders after the existing debounce and keeps the scroll position by restoring `window.scrollY`? No: JavaScript is off. Keep it simple and accept that the view scrolls to the top on change.

- [ ] **Step 1: Write the failing Core test.** `revealNavigatesAndSelects`: from `tmp`, `reveal(tmp/sub/x.md)` makes `currentURL == tmp/sub` and `selection == [x.md's item URL]`.
- [ ] **Step 2: Run** `scripts/test.sh --filter revealNavigatesAndSelects`. Expected: FAIL.
- [ ] **Step 3: Implement** `reveal` and the web view.
- [ ] **Step 4: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then by hand, with a test file `demo.md` containing:
  - headings;
  - a table with alignment;
  - a task list;
  - a fenced Swift block containing `<script>alert(1)</script>`;
  - an image `pics/ä b.png`;
  - links to `https://apple.com`, `other.md` and `#heading`;
  - `<script>document.body.innerHTML='HACKED'</script>`;
  - `[click](javascript:alert(1))`.

  Checks:
  1. Everything renders. No "HACKED" appears, and the javascript link does nothing.
  2. The apple.com link opens Safari (or the default browser), `other.md` reveals that file in the list, and `#heading` scrolls.
  3. The image shows.
  4. Switching the system to dark mode re-colors the preview.
  5. The Source toggle shows the raw text, and the choice is remembered.
  6. Editing `demo.md` in TextEdit and saving updates the preview.
  7. A 6 MB `.md` file shows the size message, and "Show Source" works.
- [ ] **Step 5: Commit** `feat: rendered Markdown preview with safe links, images and source toggle`

---

## Self-review notes
- **Spec §2.2.4 coverage:**
  - Toggleable panel with ⇧⌘P → Task 4.
  - Markdown, GitHub-flavored (headings, lists, tables, code blocks, task lists, links, relative images) → Tasks 2, 3 and 5.
  - Follows light/dark → Tasks 3 (CSS) and 5.
  - Rendered/Source toggle → Task 5.
  - Everything else uses Quick Look in the panel → Task 4.
  - Easy to add renderers → Task 3 (`PreviewRenderer` + `PreviewRegistry`; a new renderer returns HTML and reuses the web view).
- **Spec §7:** Markdown is parsed with swift-markdown (cmark-gfm), rendered to HTML and shown in a `WKWebView` with a light/dark stylesheet. The plan uses our own HTML visitor because the library's formatter doesn't escape code (a builder's-call refinement).
- **Builder's calls:**
  - Remote `https` images are allowed (README badges).
  - Raw HTML passes through with JavaScript off.
  - Local links reveal the target in the list.
  - The panel's visibility is global, not per window.
  - Archive entries preview through the Plan 3 cache. Relative images inside archived Markdown don't resolve, because only the file itself is extracted.
  - Panel width isn't persisted.

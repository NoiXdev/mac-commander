import AppKit
import MacCommanderCore
import SwiftUI
import Synchronization
import UniformTypeIdentifiers
import WebKit

/// A rendered preview (`RenderedPreview.html`) in a locked-down `WKWebView`.
///
/// - Content JavaScript is off, the data store is non-persistent (shared by all preview web views), element
///   fullscreen and force-click link previews are off and there are no user scripts. The document's CSP
///   allows images from `mcpreview:`, `https:` and `data:` only.
/// - Local resources (relative images) load through `PreviewSchemeHandler` (`mcpreview://local/<path>`).
/// - Links never navigate the web view, except `#fragment` links within the document: `http`, `https` and
///   `mailto` open in the default app, local links (relative, `mcpreview:`, `file:`) call `reveal`, anything
///   else (including `javascript:`) is ignored.
///
/// The web view is created once per view and reloaded only when the HTML or its base changes. Without
/// JavaScript a reload starts at the top again (accepted).
struct MarkdownWebView: NSViewRepresentable {
    let rendered: RenderedPreview
    /// The rendered file, to tell a `file.md#anchor` link to the shown file from a link to another file.
    let file: URL
    /// Shows a local link's target in the window's list.
    let reveal: @MainActor (URL) -> Void

    /// One non-persistent store for every preview web view, so WebKit can share WebContent processes
    /// between them instead of starting one per selected file.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.isElementFullscreenEnabled = false
        // One handler per web view: its running tasks belong to this view only.
        configuration.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewResourceURL.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // A force-click preview would load the link in a separate view, bypassing the policy below.
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.file = file
        coordinator.reveal = reveal
        guard coordinator.loadedHTML != rendered.html || coordinator.baseURL != rendered.baseURL else { return }
        coordinator.loadedHTML = rendered.html
        coordinator.baseURL = rendered.baseURL
        coordinator.isLoadingHTML = true
        webView.loadHTMLString(rendered.html, baseURL: rendered.baseURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// The navigation policy (see the type's comment) and the new-window rule.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        var baseURL: URL?
        var file: URL?
        var reveal: (@MainActor (URL) -> Void)?
        /// Set before `loadHTMLString`, cleared when that load finishes or fails: only then is a
        /// navigation of type `.other` to the base URL (or `about:blank`) the document's own load.
        var isLoadingHTML = false

        override init() {
            super.init()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if isLoadingHTML, navigationAction.navigationType == .other,
                url.absoluteString == "about:blank" || url == baseURL
            {
                return .allow
            }
            // `#anchor` (resolved against `<base href>`, i.e. the document URL) in the main frame: WebKit
            // scrolls in place.
            if navigationAction.targetFrame?.isMainFrame == true, isFragmentOfDocument(url, in: webView) {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated {
                openLink(url, in: webView)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoadingHTML = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            isLoadingHTML = false
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            isLoadingHTML = false
        }

        /// `target="_blank"` links: never a new web view. A `#anchor` in this document scrolls in place (as
        /// in the same frame); any other request follows the link rule.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if isFragmentOfDocument(url, in: webView), let current = webView.url,
                let fragment = url.fragment(percentEncoded: true)
            {
                scroll(webView, to: fragment, in: current)
            } else {
                openLink(url, in: webView)
            }
            return nil
        }

        /// `url` has a fragment and is otherwise the shown document's URL.
        private func isFragmentOfDocument(_ url: URL, in webView: WKWebView) -> Bool {
            guard url.fragment != nil, let current = webView.url else { return false }
            return Self.withoutFragment(url) == Self.withoutFragment(current)
        }

        private func openLink(_ url: URL, in webView: WKWebView) {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                PathQueries.openWithDefaultApp(url)
            case PreviewResourceURL.scheme:
                guard let target = PreviewResourceURL.fileURL(for: url) else { return }
                if let fragment = url.fragment(percentEncoded: true), !fragment.isEmpty, isShownFile(target),
                    let current = webView.url
                {
                    scroll(webView, to: fragment, in: current)
                } else {
                    reveal?(target)
                }
            case "file":
                reveal?(url.standardizedFileURL)
            default:
                break
            }
        }

        /// The base (and so the link) is the folder of the file's standardized URL, symlinks not resolved, as
        /// the renderer builds it: compare standardized paths on both sides.
        private func isShownFile(_ target: URL) -> Bool {
            guard let file else { return false }
            return target.standardizedFileURL.path == file.standardizedFileURL.path
        }

        /// `file.md#anchor` to the shown file: a fragment navigation on the document URL, which WebKit
        /// handles in place (the policy above allows it), so no JavaScript is needed.
        private func scroll(_ webView: WKWebView, to fragment: String, in current: URL) {
            guard var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return }
            components.percentEncodedFragment = fragment
            guard let target = components.url else { return }
            webView.load(URLRequest(url: target))
        }

        private static func withoutFragment(_ url: URL) -> URL? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = nil
            return components.url
        }
    }
}

/// Serves `mcpreview://local/<path>` requests from the local file system: regular files only (symlinks are
/// followed to a regular file), up to 50 MB, never dataless (iCloud / File Provider placeholders are not
/// downloaded). Reads run one at a time on `readQueue` (blocking I/O stays off the main thread and out of
/// the Swift concurrency pool). At most `maxInFlightBytes` are held between a read and its delivery per
/// handler; a read beyond that fails.
///
/// WebKit calls `start` and `stop` on the main thread. Calling a `WKURLSchemeTask` after its `stop` raises an
/// Objective-C exception, so every running task is tracked with a token: `stop` removes it, and a finished
/// read answers only while its own token is still registered (a new task may reuse a stopped task's
/// address, hence a token rather than the identifier alone).
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let maxBytes: Int64 = 50 * 1024 * 1024
    nonisolated static let maxInFlightBytes: Int64 = 100 * 1024 * 1024
    /// `SF_DATALESS` from `<sys/stat.h>`: the file's data isn't local; reading it would download it.
    nonisolated private static let datalessFlag: UInt32 = 0x4000_0000
    nonisolated private static let readQueue = DispatchQueue(
        label: "MacCommander.PreviewSchemeHandler.read", qos: .userInitiated)

    private var running: [ObjectIdentifier: UUID] = [:]
    private let budget = ByteBudget(limit: maxInFlightBytes)

    override init() {
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url, let file = PreviewResourceURL.fileURL(for: requestURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let token = UUID()
        running[id] = token
        let budget = budget
        Task { [weak self] in
            let result = await withCheckedContinuation { continuation in
                Self.readQueue.async { continuation.resume(returning: Self.read(file, budget: budget)) }
            }
            // The bytes leave this handler here: delivered below, or dropped for a stopped task.
            if case .success(let read) = result { budget.release(read.reserved) }
            guard let self, running[id] == token else { return }
            running[id] = nil
            switch result {
            case .success(let read):
                let data = read.data
                let response = URLResponse(
                    url: requestURL, mimeType: Self.mimeType(for: file),
                    expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running[ObjectIdentifier(urlSchemeTask)] = nil
    }

    private static func mimeType(for file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The file's bytes: a regular, non-dataless file (a symlink only when its target is one), at most
    /// `maxBytes`. Opened without following a symlink and non-blocking (a FIFO swapped in never blocks), then
    /// checked again with `fstat` on the opened descriptor, so a file replaced after the `lstat` is still
    /// checked. On success `reserved` bytes are taken from `budget`; the caller releases them.
    nonisolated private static func read(
        _ file: URL, budget: ByteBudget
    ) -> Result<(data: Data, reserved: Int64), URLError> {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return .failure(URLError(.fileDoesNotExist)) }
        var path = file.path
        if info.st_mode & S_IFMT == S_IFLNK {
            path = file.resolvingSymlinksInPath().path
            guard lstat(path, &info) == 0 else { return .failure(URLError(.fileDoesNotExist)) }
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(URLError(.fileIsDirectory)) }
        guard info.st_flags & datalessFlag == 0 else { return .failure(URLError(.resourceUnavailable)) }
        guard info.st_size <= maxBytes else { return .failure(URLError(.dataLengthExceedsMaximum)) }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .failure(URLError(.noPermissionsToReadFile)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & datalessFlag == 0,
            info.st_size <= maxBytes
        else {
            return .failure(URLError(.fileDoesNotExist))
        }
        // The read may return up to `maxBytes`, whatever the size said: reserve that much at most.
        let reserved = min(max(info.st_size, 0) + 1, maxBytes + 1)
        guard budget.reserve(reserved) else { return .failure(URLError(.dataLengthExceedsMaximum)) }
        do {
            let data = try handle.read(upToCount: Int(maxBytes) + 1) ?? Data()
            guard data.count <= maxBytes else {
                budget.release(reserved)
                return .failure(URLError(.dataLengthExceedsMaximum))
            }
            return .success((data, reserved))
        } catch {
            budget.release(reserved)
            return .failure(URLError(.cannotOpenFile))
        }
    }
}

/// Bytes reserved by reads between `PreviewSchemeHandler.readQueue` and delivery on the main thread.
private final class ByteBudget: Sendable {
    private let limit: Int64
    private let used = Mutex<Int64>(0)

    init(limit: Int64) {
        self.limit = limit
    }

    /// Takes `bytes` when they fit under the limit.
    func reserve(_ bytes: Int64) -> Bool {
        used.withLock { used in
            guard used + bytes <= limit else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int64) {
        used.withLock { $0 -= bytes }
    }
}

import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct PreviewRendererTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func registryPicksMarkdown() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = PreviewRegistry.standard
        #expect(registry.renderer(for: dir.appendingPathComponent("a.MD"))?.id == "markdown")
        #expect(registry.renderer(for: dir.appendingPathComponent("b.markdown"))?.id == "markdown")
        #expect(registry.renderer(for: dir.appendingPathComponent("c.txt")) == nil)
        #expect(registry.renderer(for: dir) == nil)
        let folderMd = dir.appendingPathComponent("x.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folderMd, withIntermediateDirectories: true)
        #expect(registry.renderer(for: folderMd) == nil)
    }

    @Test func folderNamedMdIsUnreadable() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folderMd = dir.appendingPathComponent("x.md")
        try FileManager.default.createDirectory(at: folderMd, withIntermediateDirectories: true)
        do {
            _ = try await MarkdownPreviewRenderer().render(folderMd)
            Issue.record("expected .unreadable")
        } catch {
            guard case .unreadable = error else {
                Issue.record("expected .unreadable, got \(error)")
                return
            }
        }
    }

    @Test func rendersDocumentWithBaseAndCSP() async throws {
        let dir = try tempDir().appendingPathComponent("My Docs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("readme.md")
        let text = "# Hi\n![p](<pics/ä b.png>)"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let result = try await MarkdownPreviewRenderer().render(file)
        let meta =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src &#39;none&#39;; img-src mcpreview: https: data:; style-src &#39;unsafe-inline&#39;; font-src mcpreview: data:\">"
        let metaRange = try #require(result.html.range(of: meta))
        let baseRange = try #require(result.html.range(of: "<base "))
        #expect(metaRange.lowerBound < baseRange.lowerBound)
        #expect(result.html.contains("<base href=\"mcpreview://local/"))
        #expect(result.html.contains("My%20Docs/\">"))
        #expect(result.html.contains("<h1 id=\"hi\">Hi</h1>"))
        #expect(result.html.contains("src=\"pics/ä b.png\""))
        #expect(result.source == text)
        #expect(result.baseURL.absoluteString.hasSuffix("My%20Docs/"))
    }

    @Test func tooLargeThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.md")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try FileHandle(forWritingTo: file)
        try h.truncate(atOffset: 6_000_000)
        try h.close()
        await #expect(throws: PreviewError.tooLarge(bytes: 6_000_000)) {
            try await MarkdownPreviewRenderer().render(file)
        }
        let text = try await MarkdownPreviewRenderer.sourceText(of: file)
        #expect(text.hasSuffix("\n… (truncated)"))
        #expect(text.utf8.count <= 5_000_000 + "\n… (truncated)".utf8.count)
    }

    @Test func latin1Fallback() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("l.md")
        try Data([0x47, 0x72, 0xFC, 0xDF, 0x65]).write(to: file)
        let result = try await MarkdownPreviewRenderer().render(file)
        #expect(result.source == "Grüße")
        #expect(result.html.contains("Grüße"))
        // 0x81 is undefined in CP1252, so this reaches the ISO Latin-1 branch.
        let raw = dir.appendingPathComponent("raw.md")
        try Data([0x47, 0x81, 0xFC]).write(to: raw)
        #expect(try await MarkdownPreviewRenderer.sourceText(of: raw) == "G\u{81}ü")
    }

    @Test func utf8BomAndUTF16() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("# ä".utf8)).write(to: a)
        #expect(try await MarkdownPreviewRenderer.sourceText(of: a) == "# ä")
        let b = dir.appendingPathComponent("b.md")
        try (Data([0xFF, 0xFE]) + "# ä".data(using: .utf16LittleEndian)!).write(to: b)
        #expect(try await MarkdownPreviewRenderer.sourceText(of: b) == "# ä")
    }

    @Test func binaryFileDoesNotHang() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.md")
        var rng = SystemRandomNumberGenerator()
        try Data((0..<1_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: file)
        let start = ContinuousClock.now
        _ = try await MarkdownPreviewRenderer().render(file)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func truncationDoesNotSplitUTF8Character() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("emoji.md")
        // The 4-byte emoji starts at byte 4,999,998, so the 5,000,000 cut lands inside it.
        let pad = String(repeating: "a", count: 4_999_998)
        try Data((pad + "😀 tail").utf8).write(to: file)
        let text = try await MarkdownPreviewRenderer.sourceText(of: file)
        #expect(text == pad + "\n… (truncated)")
        #expect(!text.contains("ð") && !text.contains("\u{FFFD}"))
    }

    @Test func truncationDoesNotSplitUTF16SurrogatePair() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("u16.md")
        // BOM (2 bytes) + 2,499,998 units = 4,999,998 bytes, then a surrogate pair cut after its high half.
        let pad = String(repeating: "a", count: 2_499_998)
        try (Data([0xFF, 0xFE]) + (pad + "😀 tail").data(using: .utf16LittleEndian)!).write(to: file)
        let text = try await MarkdownPreviewRenderer.sourceText(of: file)
        #expect(text == pad + "\n… (truncated)")
    }

    @Test func symlinkedMarkdownRendersWithLinkFolderAsBase() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("r.md")
        try "# Linked".write(to: target, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = sub.appendingPathComponent("README.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try await MarkdownPreviewRenderer().render(link)
        #expect(result.html.contains("<h1 id=\"linked\">Linked</h1>"))
        #expect(result.baseURL.absoluteString.hasSuffix("/links/"))
        #expect(try await MarkdownPreviewRenderer.sourceText(of: link) == "# Linked")
    }

    @Test func danglingSymlinkIsUnreadable() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("gone.md")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.appendingPathComponent("missing.md"))
        do {
            _ = try await MarkdownPreviewRenderer().render(link)
            Issue.record("expected .unreadable")
        } catch {
            guard case .unreadable = error else {
                Issue.record("expected .unreadable, got \(error)")
                return
            }
        }
    }
}

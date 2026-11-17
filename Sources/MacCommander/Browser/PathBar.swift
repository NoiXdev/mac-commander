import AppKit
import MacCommanderCore
import SwiftUI

/// Clickable breadcrumb of the current folder.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        let segments = PathUtilities.segments(of: model.currentURL)
        // A few `stat`s, cheap. Segments inside the archive are virtual: folder icons, no file lookups.
        let archivePath = ArchivePath.split(model.currentURL)?.archive.path
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await model.navigate(to: url) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: Self.icon(for: url, archivePath: archivePath))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(url.path == "/" ? Self.rootName : BrowserWindow.displayName(of: url))
                        }
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .onAppear { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
        .onChange(of: model.currentURL) { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
        }
        .background(.bar)
    }

    private static var rootName: String { FileManager.default.displayName(atPath: "/") }

    /// The archive file itself keeps its file icon; paths inside it get the folder icon.
    private static func icon(for url: URL, archivePath: String?) -> NSImage {
        if let archivePath, url.path.hasPrefix(archivePath + "/") {
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

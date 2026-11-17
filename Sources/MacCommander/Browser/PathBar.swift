import AppKit
import MacCommanderCore
import SwiftUI

/// Clickable breadcrumb of the current folder.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        let segments = PathUtilities.segments(of: model.currentURL)
        // Segments inside the shown archive are virtual: folder icons, no file lookups. Taken from the model
        // (no disk access); it lags behind while a new folder loads, which only affects icons meanwhile.
        let archivePath = model.archiveLocation?.archive.path
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
                        PathSegmentLabel(url: url, isVirtual: archivePath.map { url.path.hasPrefix($0 + "/") } ?? false)
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
}

/// One breadcrumb: a folder icon and the last path component at once, then the Finder name and the item's
/// own icon, looked up off the main actor (the folder may be on a network volume).
private struct PathSegmentLabel: View {
    let url: URL
    /// A path inside an archive: the folder icon and the plain name are final.
    let isVirtual: Bool
    private let resolvedState = State<Resolved?>(initialValue: nil)
    private var resolved: Resolved? {
        get { resolvedState.wrappedValue }
        nonmutating set { resolvedState.wrappedValue = newValue }
    }

    private struct Resolved: Sendable {
        let url: URL
        let name: String
        let icon: NSImage
    }

    var body: some View {
        let current = resolved?.url == url ? resolved : nil
        HStack(spacing: 4) {
            Image(nsImage: current?.icon ?? Self.folderIcon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(current?.name ?? (url.path == "/" ? "/" : url.lastPathComponent))
        }
        .task(id: url) {
            guard !isVirtual else { return }
            resolved = await Self.resolve(url)
        }
    }

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    @concurrent
    private static func resolve(_ url: URL) async -> Resolved {
        Resolved(url: url, name: await PathQueries.displayName(url), icon: NSWorkspace.shared.icon(forFile: url.path))
    }
}

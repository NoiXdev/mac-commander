import AppKit
import MacCommanderCore
import SwiftUI

/// What the info window shows for one item; read once off the main actor.
struct ItemInfo: Sendable {
    var name: String
    var kind: String
    var isDirectory: Bool
    var fileSize: Int64?
    var created: Date?
    var modified: Date?
    var parent: String
    var tags: [FileTag]

    /// One `resourceValues` call and the tag attribute; can stall on network volumes, so it runs on the
    /// blocking-I/O queue.
    static func load(_ url: URL) async -> ItemInfo {
        await PathQueries.run { loadNow(url) }
    }

    private static func loadNow(_ url: URL) -> ItemInfo {
        let values = try? url.resourceValues(forKeys: [
            .localizedNameKey, .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey,
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        return ItemInfo(
            name: values?.localizedName ?? url.lastPathComponent,
            kind: values?.localizedTypeDescription ?? "",
            isDirectory: values?.isDirectory ?? false,
            fileSize: values?.fileSize.map(Int64.init),
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            parent: url.deletingLastPathComponent().path,
            tags: TagStore.readNow(url))
    }
}

/// Read-only information about one item. The folder size is computed in `.task`, which SwiftUI cancels
/// when the window closes.
struct InfoWindow: View {
    let url: URL
    /// Tag edits are announced here, so file lists showing the item's folder re-list it.
    let operations: FileOperationCenter
    private let infoState = State<ItemInfo?>(initialValue: nil)
    private let iconState = State<NSImage?>(initialValue: nil)
    private let sizeState = State(initialValue: "")
    private var info: ItemInfo? {
        get { infoState.wrappedValue }
        nonmutating set { infoState.wrappedValue = newValue }
    }
    private var icon: NSImage? {
        get { iconState.wrappedValue }
        nonmutating set { iconState.wrappedValue = newValue }
    }
    private var sizeText: String {
        get { sizeState.wrappedValue }
        nonmutating set { sizeState.wrappedValue = newValue }
    }

    private static let dateStyle = Date.FormatStyle(date: .long, time: .shortened)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: icon ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(info?.name ?? url.lastPathComponent)
                    .font(.title3.bold())
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(String(localized: "Kind"), info?.kind ?? "")
                row(String(localized: "Size"), sizeText)
                row(String(localized: "Created"), info?.created.map { $0.formatted(Self.dateStyle) } ?? "")
                row(String(localized: "Modified"), info?.modified.map { $0.formatted(Self.dateStyle) } ?? "")
                row(String(localized: "Where"), info?.parent ?? "")
                tagsRow
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .navigationTitle(String(localized: "\(info?.name ?? url.lastPathComponent) Info"))
        .task(id: url) { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Chips with a remove button, then "+" for the Tags menu. Every edit is written, then the info reloaded.
    private var tagsRow: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(String(localized: "Tags"))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TagChipFlow(spacing: 4) {
                ForEach(info?.tags ?? [], id: \.self) { tag in
                    tagChip(tag)
                }
                Button {
                    showTagMenu()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Add or remove tags"))
                .disabled(info == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tagChip(_ tag: FileTag) -> some View {
        HStack(spacing: 4) {
            Image(nsImage: TagMenu.dotImage(tag.color))
            Text(tag.name)
            Button {
                Task { await editTags(.remove(tag)) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove “\(tag.name)”"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    /// The Tags submenu as a pop-up menu at the mouse.
    private func showTagMenu() {
        guard let info else { return }
        let item = TagMenu.make(for: [url], current: [info.tags], window: NSApp.keyWindow) {
            Task { await reloadInfo() }
        }
        guard let menu = item.submenu else { return }
        item.submenu = nil
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func editTags(_ change: TagChange) async {
        do {
            try await TagStore.setTags(change, on: [url])
        } catch {
            NSAlert(error: error).runModal()
        }
        await reloadInfo()
    }

    /// After a tag edit: lists showing the folder re-list it (the folder watcher can't see tag changes),
    /// and the info is read again.
    private func reloadInfo() async {
        operations.announceChanged(folders: [url.deletingLastPathComponent()])
        info = await ItemInfo.load(url)
    }

    private func load() async {
        // The generic icon at once (no disk access), the item's own once loaded off the main actor.
        icon = NSWorkspace.shared.icon(for: .item)
        // Icon and info load concurrently.
        async let fileIcon = Self.fileIcon(url)
        let loaded = await ItemInfo.load(url)
        icon = await fileIcon
        info = loaded
        guard loaded.isDirectory else {
            sizeText = loaded.fileSize.map(Self.fileSizeText) ?? "--"
            return
        }
        sizeText = String(localized: "Calculating…")
        do {
            let size = try await FolderSizeCalculator.size(of: url)
            let count = size.items.formatted()
            let items = size.items == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
            sizeText = String(localized: "\(Self.byteString(size.bytes)) for \(items) (\(size.bytes.formatted()) bytes)")
        } catch is CancellationError {
            sizeText = ""
        } catch {
            sizeText = "--"
        }
    }

    /// `NSWorkspace.icon(forFile:)` touches the disk (and can stall on network volumes): off the main thread.
    private static func fileIcon(_ url: URL) async -> NSImage {
        await PathQueries.run { NSWorkspace.shared.icon(forFile: url.path) }
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func fileSizeText(_ bytes: Int64) -> String {
        "\(byteString(bytes)) (\(bytes.formatted()) bytes)"
    }
}

/// Lays its subviews out left to right, wrapping to a new line when the width runs out.
private struct TagChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(for: subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

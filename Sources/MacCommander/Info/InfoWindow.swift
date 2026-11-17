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

    /// One `resourceValues` call; can stall on network volumes, so call it off the main actor.
    @concurrent static func load(_ url: URL) async -> ItemInfo {
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
            parent: url.deletingLastPathComponent().path)
    }
}

/// Read-only information about one item. The folder size is computed in `.task`, which SwiftUI cancels
/// when the window closes.
struct InfoWindow: View {
    let url: URL
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

    private func load() async {
        // The generic icon at once (no disk access), the item's own once loaded off the main actor.
        icon = NSWorkspace.shared.icon(for: .item)
        icon = await Self.fileIcon(url)
        let loaded = await ItemInfo.load(url)
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
    @concurrent
    private static func fileIcon(_ url: URL) async -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func fileSizeText(_ bytes: Int64) -> String {
        "\(byteString(bytes)) (\(bytes.formatted()) bytes)"
    }
}

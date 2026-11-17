import AppKit
import MacCommanderCore
import UniformTypeIdentifiers

extension NSUserInterfaceItemIdentifier {
    static let checkboxColumn = NSUserInterfaceItemIdentifier("checkbox")
    static let checkboxCell = NSUserInterfaceItemIdentifier("checkboxCell")
    static let nameCell = NSUserInterfaceItemIdentifier("nameCell")
    static let textCell = NSUserInterfaceItemIdentifier("textCell")
    static let rightAlignedTextCell = NSUserInterfaceItemIdentifier("rightAlignedTextCell")

    /// The column identifier of a `FileColumn` is its raw value.
    init(_ column: FileColumn) {
        self.init(column.rawValue)
    }
}

/// Name column: icon + name. `hasFileIcon` is false while a type placeholder is shown.
final class FileNameCellView: NSTableCellView {
    var hasFileIcon = false

    init() {
        super.init(frame: .zero)
        identifier = .nameCell
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Date, size, kind and tags columns: a single secondary-colored label.
final class FileTextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.alignment = alignment
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Checkbox column: mirrors whether the row is selected. Not interactive itself: clicks pass
/// through to `FileOutlineView`, which toggles the row's selection.
final class CheckboxCellView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        identifier = .checkboxCell
        checkbox.refusesFirstResponder = true
        checkbox.imagePosition = .imageOnly
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Cell text for the non-name columns.
@MainActor
enum FileListFormat {
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    private static let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func text(for column: FileColumn, of item: FileItem) -> String {
        switch column {
        case .name: item.name
        case .dateModified: date(item.dateModified)
        case .dateCreated: date(item.dateCreated)
        case .dateAdded: date(item.dateAdded)
        case .size: item.isDirectory ? "--" : item.size.map { sizeFormatter.string(fromByteCount: $0) } ?? "--"
        case .kind: item.kind
        case .tags: ""
        }
    }

    private static func date(_ date: Date?) -> String {
        guard let date else { return "--" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let time = date.formatted(timeStyle)
            return String(localized: "Today at \(time)")
        }
        if calendar.isDateInYesterday(date) {
            let time = date.formatted(timeStyle)
            return String(localized: "Yesterday at \(time)")
        }
        return date.formatted(dateStyle)
    }
}

/// 16 pt file icons. A type icon (cached per extension) is shown at once; the file's own icon
/// (`NSWorkspace.icon(forFile:)`, which touches the disk) is loaded later for visible rows only.
@MainActor
final class FileIconProvider {
    private static let iconSize = NSSize(width: 16, height: 16)
    private let fileIcons = NSCache<NSURL, NSImage>()
    private var typeIcons: [String: NSImage] = [:]

    init() {
        fileIcons.countLimit = 5000
    }

    func cachedFileIcon(for url: URL) -> NSImage? {
        fileIcons.object(forKey: url as NSURL)
    }

    func placeholder(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : item.url.pathExtension.lowercased()
        if let icon = typeIcons[key] { return icon }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        // Copy before resizing: NSWorkspace may hand out shared image instances.
        let icon = NSWorkspace.shared.icon(for: type).copy() as? NSImage ?? NSImage()
        icon.size = Self.iconSize
        typeIcons[key] = icon
        return icon
    }

    func loadFileIcon(for url: URL) -> NSImage {
        if let icon = cachedFileIcon(for: url) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage ?? NSImage()
        icon.size = Self.iconSize
        fileIcons.setObject(icon, forKey: url as NSURL)
        return icon
    }
}

import Foundation

/// How tall the file list's rows are. Text stays 13 pt in every size.
public enum RowSize: String, Codable, CaseIterable, Sendable {
    case compact, regular, large

    /// Row height in points.
    public var rowHeight: Double {
        switch self {
        case .compact: 20
        case .regular: 24
        case .large: 36
        }
    }

    /// The name shown in Settings ▸ View.
    public var title: String {
        switch self {
        case .compact: L10n.string("settings.view.rowSize.compact", "Compact")
        case .regular: L10n.string("settings.view.rowSize.regular", "Default")
        case .large: L10n.string("settings.view.rowSize.large", "Large")
        }
    }

    /// Icon edge length in points.
    public var iconSize: Double {
        switch self {
        case .compact, .regular: 16
        case .large: 32
        }
    }
}

extension RowSize {
    /// The scroll offset that keeps the same row at the top of the visible area when every row's height
    /// changes from `oldHeight` to `newHeight` (a list of equally tall rows, starting at 0). `offset` is the
    /// clip view's vertical origin; the visible area starts `topInset` below it (e.g. under a toolbar).
    public static func scrollOffset(
        _ offset: Double, topInset: Double, from oldHeight: Double, to newHeight: Double
    ) -> Double {
        guard oldHeight > 0 else { return offset }
        return (offset + topInset) / oldHeight * newHeight - topInset
    }
}

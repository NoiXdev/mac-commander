import Foundation
import Observation

public struct ColumnState: Codable, Equatable, Sendable {
    public var column: FileColumn
    public var width: Double
    public var isVisible: Bool

    public init(column: FileColumn, width: Double, isVisible: Bool) {
        self.column = column
        self.width = width
        self.isVisible = isVisible
    }
}

public struct ColumnLayout: Codable, Equatable, Sendable {
    public var columns: [ColumnState]

    public static let `default` = ColumnLayout(columns: [
        ColumnState(column: .name, width: 280, isVisible: true),
        ColumnState(column: .dateModified, width: 170, isVisible: true),
        ColumnState(column: .size, width: 80, isVisible: true),
        ColumnState(column: .kind, width: 140, isVisible: true),
        ColumnState(column: .tags, width: 90, isVisible: true),
        ColumnState(column: .dateCreated, width: 170, isVisible: false),
        ColumnState(column: .dateAdded, width: 170, isVisible: false),
        ColumnState(column: .location, width: 200, isVisible: true),
    ])

    public init(columns: [ColumnState]) {
        self.columns = columns
    }

    private enum CodingKeys: String, CodingKey { case columns }

    /// Decodes leniently: unknown columns are dropped, missing ones appended from the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var raw = try container.nestedUnkeyedContainer(forKey: .columns)
        var result: [ColumnState] = []
        while !raw.isAtEnd {
            if let state = try? raw.decode(ColumnState.self) {
                if !result.contains(where: { $0.column == state.column }) {
                    result.append(state)
                }
            } else {
                // Skip the undecodable element (e.g. unknown column name).
                _ = try raw.decode(AnyDecodable.self)
            }
        }
        for state in Self.default.columns where !result.contains(where: { $0.column == state.column }) {
            result.append(state)
        }
        columns = result
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

public struct ViewSettings: Codable, Equatable, Sendable {
    public var columnLayout = ColumnLayout.default
    public var sortOrder = FileSortOrder.default
    public var showHiddenFiles = false
    public var showCheckboxColumn = true
    public var showPreview = false
    public var markdownShowsSource = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case columnLayout, sortOrder, showHiddenFiles, showCheckboxColumn
        case showPreview, markdownShowsSource
    }

    /// Lenient decoding: a missing or unreadable field falls back to its default only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ViewSettings()
        columnLayout = (try? c.decodeIfPresent(ColumnLayout.self, forKey: .columnLayout)) ?? d.columnLayout
        sortOrder = (try? c.decodeIfPresent(FileSortOrder.self, forKey: .sortOrder)) ?? d.sortOrder
        showHiddenFiles = (try? c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles)) ?? d.showHiddenFiles
        showCheckboxColumn =
            (try? c.decodeIfPresent(Bool.self, forKey: .showCheckboxColumn)) ?? d.showCheckboxColumn
        showPreview = (try? c.decodeIfPresent(Bool.self, forKey: .showPreview)) ?? d.showPreview
        markdownShowsSource =
            (try? c.decodeIfPresent(Bool.self, forKey: .markdownShowsSource)) ?? d.markdownShowsSource
    }
}

@MainActor @Observable
public final class ViewSettingsStore {
    static let key = "viewSettings.v1"

    @ObservationIgnored private let defaults: UserDefaults

    public var settings: ViewSettings {
        didSet { persist() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(ViewSettings.self, from: data)
        {
            settings = decoded
        } else {
            // Missing or undecodable: use defaults without touching the stored value.
            settings = ViewSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

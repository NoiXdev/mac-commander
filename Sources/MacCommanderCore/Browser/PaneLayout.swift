import Foundation
import Observation

/// The panes of one window: one `BrowserModel`, or two side by side. `panes[0]` is the left pane.
/// Owns which pane is active, the focus requests and the per-pane search field text.
@MainActor @Observable
public final class PaneLayout {
    /// One or two panes; panes[0] is the left. In single-pane mode the only pane is panes[0].
    public private(set) var panes: [BrowserModel]
    public private(set) var activeIndex = 0
    /// The folder the second pane reopens at, kept from the last time dual mode was closed.
    public private(set) var rememberedSecondFolder: URL?
    /// Incremented whenever a pane should take keyboard focus; `focusTarget` is that pane.
    public private(set) var focusSerial = 0
    public private(set) var focusTarget: ObjectIdentifier?
    /// The request the window's transfer sheet shows; set by `requestTransfer`, cleared by the sheet.
    public var pendingTransfer: PaneTransferRequest?

    @ObservationIgnored private let makePane: @MainActor (URL) -> BrowserModel
    private var searchTexts: [ObjectIdentifier: String] = [:]
    /// The panes whose list is renaming an item inline (reported by the UI).
    private var renamingPanes: Set<ObjectIdentifier> = []

    public init(
        primary: BrowserModel, rememberedSecondFolder: URL? = nil,
        makePane: @escaping @MainActor (URL) -> BrowserModel
    ) {
        panes = [primary]
        self.rememberedSecondFolder = rememberedSecondFolder
        self.makePane = makePane
    }

    public var isDual: Bool { panes.count == 2 }
    public var active: BrowserModel { panes[activeIndex] }
    /// nil in single-pane mode.
    public var inactive: BrowserModel? { isDual ? panes[1 - activeIndex] : nil }

    // MARK: - Mode

    public func showDual() {
        guard !isDual else { return }
        panes.append(makePane(rememberedSecondFolder ?? active.currentURL))
    }

    /// Keeps the active pane (it becomes `panes[0]`) and remembers the other pane's folder.
    public func showSingle() {
        guard let removed = inactive else { return }
        rememberedSecondFolder = removed.currentURL
        searchTexts[ObjectIdentifier(removed)] = nil
        renamingPanes.remove(ObjectIdentifier(removed))
        panes = [active]
        activeIndex = 0
    }

    // MARK: - Active pane and focus

    public func activate(_ pane: BrowserModel) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        activeIndex = index
    }

    public func switchActive() {
        guard let other = inactive else { return }
        activate(other)
        requestFocus(other)
    }

    public func requestFocus(_ pane: BrowserModel) {
        focusTarget = ObjectIdentifier(pane)
        focusSerial += 1
    }

    // MARK: - Search text

    public func searchText(for pane: BrowserModel) -> String {
        searchTexts[ObjectIdentifier(pane)] ?? ""
    }

    public func setSearchText(_ text: String, for pane: BrowserModel) {
        searchTexts[ObjectIdentifier(pane)] = text
    }

    // MARK: - Inline rename

    /// The active pane's list is renaming an item inline; Copy/Move to Other Pane is off meanwhile.
    public var isActiveRenaming: Bool { renamingPanes.contains(ObjectIdentifier(active)) }

    public func setRenaming(_ isRenaming: Bool, for pane: BrowserModel) {
        let id = ObjectIdentifier(pane)
        if isRenaming { renamingPanes.insert(id) } else { renamingPanes.remove(id) }
    }

    // MARK: - Cross-pane folders

    /// The inactive pane's folder when it shows a real folder (no search/tag view, not in an archive, no
    /// load error, not disconnected); else nil. Always nil in single-pane mode.
    public var transferTarget: URL? {
        guard let inactive, Self.showsRealFolder(inactive) else { return nil }
        return inactive.currentURL
    }

    public var canShowActiveFolderInOtherPane: Bool {
        isDual && Self.showsRealFolder(active)
    }

    /// Exchanges the two panes' folders (one history entry each, so Back undoes it per pane).
    /// Both navigations run at once, so a slow or dead server behind one pane doesn't hold up the other.
    public func swapFolders() async {
        guard let other = inactive else { return }
        let activePane = active
        let activeURL = activePane.currentURL
        let otherURL = other.currentURL
        async let toOther = activePane.navigate(to: otherURL)
        async let toActive = other.navigate(to: activeURL)
        _ = await (toOther, toActive)
    }

    public func showActiveFolderInOtherPane() async {
        guard canShowActiveFolderInOtherPane, let other = inactive else { return }
        await other.navigate(to: active.currentURL)
    }

    private static func showsRealFolder(_ pane: BrowserModel) -> Bool {
        !pane.isSearching && pane.archiveLocation == nil && pane.loadError == nil && pane.disconnectedShare == nil
    }
}

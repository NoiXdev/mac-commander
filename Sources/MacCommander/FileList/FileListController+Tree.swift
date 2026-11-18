import AppKit
import MacCommanderCore
import Observation
import SwiftUI

/// One outline row. A reference type, so `NSOutlineView` sees a stable identity per URL across
/// updates. URLs are the loader's spelling (from `model.items` / `model.children(of:)`).
@MainActor
final class FileNode {
    let url: URL
    var item: FileItem
    weak var parent: FileNode?
    /// Loaded children of a folder; nil until loaded. Cleared on reload unless the folder is expanded.
    var children: [FileNode]?
    /// False once the node left the tree; late child listings for it are dropped.
    private(set) var isAttached = true
    var loadTask: Task<Void, Never>?

    init(item: FileItem, parent: FileNode?) {
        url = item.url
        self.item = item
        self.parent = parent
    }

    func detach() {
        isAttached = false
        loadTask?.cancel()
        loadTask = nil
        children?.forEach { $0.detach() }
    }
}


extension FileListController {
    // MARK: - Items

    /// Shows `model.items`. Rows belong to `model.listedURL`, the folder the items were listed
    /// from; items of a folder that is no longer current are not shown. A new folder resets the
    /// tree; the same folder is diffed by URL, keeping scroll position, selection and expansion.
    /// Loaded subfolders are re-listed if expanded and dropped from the cache otherwise.
    /// While a search is shown the rows are its results, over the current folder (whether or not its own
    /// listing arrived); a new search resets the tree like a new folder.
    func applyItems() {
        updateEmptyLabel()
        let isCurrent = model.isSearching || (model.listedURL != nil && model.listedURL == model.currentURL)
        let items = isCurrent ? model.items : []
        let folder = isCurrent ? model.currentURL : nil
        if folder != displayedFolder || model.search != displayedSearch {
            displayedFolder = folder
            displayedSearch = model.search
            roots.forEach { $0.detach() }
            expandedURLs = []
            roots = items.map { FileNode(item: $0, parent: nil) }
            applyingChanges { outlineView.reloadData() }
            if outlineView.numberOfRows > 0 { outlineView.scrollRowToVisible(0) }
            syncSelectionFromModel()
            startPendingRename()
            return
        }
        applyingChanges {
            apply(items, in: nil)
            restoreExpansion(in: roots)
        }
        refreshLoadedFolders(in: roots)
        syncSelectionFromModel()
        repairRenameSession()
        startPendingRename()
    }

    /// Replaces the children of `parent` (nil = root) by `items`, reusing nodes by URL. Uses row
    /// inserts/removals when the order of the remaining rows is unchanged, otherwise a reload.
    func apply(_ items: [FileItem], in parent: FileNode?) {
        let old = parent.map { $0.children ?? [] } ?? roots
        var oldByURL: [URL: FileNode] = [:]
        oldByURL.reserveCapacity(old.count)
        for node in old { oldByURL[node.url] = node }

        var newNodes: [FileNode] = []
        newNodes.reserveCapacity(items.count)
        var inserted = IndexSet()
        var changed: [FileNode] = []
        for (index, item) in items.enumerated() {
            if let node = oldByURL.removeValue(forKey: item.url) {
                if node.item != item {
                    node.item = item
                    changed.append(node)
                }
                newNodes.append(node)
            } else {
                newNodes.append(FileNode(item: item, parent: parent))
                inserted.insert(index)
            }
        }
        // What's left in `oldByURL` is gone.
        var removed = IndexSet()
        for (index, node) in old.enumerated() where oldByURL[node.url] === node {
            removed.insert(index)
            node.detach()
        }
        let keptOld = old.enumerated().lazy.filter { !removed.contains($0.offset) }.map(\.element)
        let keptNew = newNodes.enumerated().lazy.filter { !inserted.contains($0.offset) }.map(\.element)
        let orderPreserved = keptOld.elementsEqual(keptNew, by: ===)

        if let parent { parent.children = newNodes } else { roots = newNodes }

        let changeCount = inserted.count + removed.count + changed.count
        if old.isEmpty || !orderPreserved || changeCount > Self.maxIncrementalChanges {
            reload(parent)
            return
        }
        if !inserted.isEmpty || !removed.isEmpty {
            outlineView.beginUpdates()
            outlineView.removeItems(at: removed, inParent: parent, withAnimation: [])
            outlineView.insertItems(at: inserted, inParent: parent, withAnimation: [])
            outlineView.endUpdates()
        }
        for node in changed { outlineView.reloadItem(node) }
    }

    func reload(_ parent: FileNode?) {
        if let parent {
            outlineView.reloadItem(parent, reloadChildren: true)
        } else {
            outlineView.reloadData()
        }
    }

    /// Re-expands folders in `expandedURLs` among `nodes` (recursively), listing them if needed.
    func restoreExpansion(in nodes: [FileNode]) {
        guard !expandedURLs.isEmpty else { return }
        for node in nodes where expandedURLs.contains(node.url) {
            if let children = node.children {
                if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                restoreExpansion(in: children)
            } else if node.loadTask == nil {
                loadChildren(of: node, expand: true)
            }
        }
    }

    /// After a reload: re-lists expanded folders and clears the cached children of collapsed ones.
    func refreshLoadedFolders(in nodes: [FileNode]) {
        for node in nodes {
            guard let children = node.children else { continue }
            if outlineView.isItemExpanded(node) {
                loadChildren(of: node, expand: false)
                refreshLoadedFolders(in: children)
            } else {
                children.forEach { $0.detach() }
                node.children = nil
                applyingChanges { outlineView.reloadItem(node, reloadChildren: true) }
            }
        }
    }

    /// Lists a folder's children through the model, then shows them (and expands if asked).
    func loadChildren(of node: FileNode, expand: Bool) {
        node.loadTask?.cancel()
        node.loadTask = Task { [weak self, model] in
            let items: [FileItem]
            do {
                items = try await model.children(of: node.url)
            } catch {
                // An unreadable subfolder expands to nothing, like in Finder.
                items = []
            }
            guard !Task.isCancelled, node.isAttached, let self else { return }
            node.loadTask = nil
            didLoadChildren(items, of: node, expand: expand)
        }
    }

    func didLoadChildren(_ items: [FileItem], of node: FileNode, expand: Bool) {
        applyingChanges {
            if node.children == nil {
                node.children = items.map { FileNode(item: $0, parent: node) }
                outlineView.reloadItem(node, reloadChildren: true)
            } else {
                apply(items, in: node)
            }
            if expand {
                expandedURLs.insert(node.url)
                outlineView.expandItem(node)
            }
            if outlineView.isItemExpanded(node), let children = node.children {
                restoreExpansion(in: children)
            }
        }
        syncSelectionFromModel()
        repairRenameSession()
        startPendingRename()
    }

    // MARK: - Operations

    /// File operations and undo post the folders they changed (in every window). The model reloads the
    /// current folder; inline-expanded subfolders are not watched, so the list re-lists those itself.
    /// The selector-based observer is removed automatically when the controller goes away.
    func observeOperationFolders() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(operationFoldersDidChange(_:)), name: FileOperationCenter.foldersDidChange,
            object: model.operations)
    }

    @objc func operationFoldersDidChange(_ notification: Notification) {
        let folders = notification.userInfo?["folders"] as? [URL] ?? []
        // Posted on the main actor; re-list on the next turn, after the operation's own updates.
        Task { @MainActor [weak self] in await self?.refreshLoadedSubfolders(matching: folders) }
    }

    /// Re-lists every loaded subfolder (children cached, expanded or not) whose canonical path is one of
    /// `folders`. Re-listing is done per node rather than by reloading the root, which Observation may skip
    /// when the root's items didn't change. The canonical paths are resolved off the main actor (the folders
    /// may be on a network volume); nodes dropped meanwhile are skipped.
    func refreshLoadedSubfolders(matching folders: [URL]) async {
        guard !folders.isEmpty, showsCurrentFolder else { return }
        let candidates = loadedSubfolders().map(\.url)
        guard !candidates.isEmpty else { return }
        let matched = Set(await PathQueries.run { PathUtilities.folders(candidates, matching: folders) })
        // Collected again: the tree may have changed during the lookup.
        guard showsCurrentFolder else { return }
        for node in loadedSubfolders() where matched.contains(node.url) {
            loadChildren(of: node, expand: false)
        }
    }

    /// The nodes whose children are loaded (expanded or not), depth first.
    private func loadedSubfolders() -> [FileNode] {
        var loaded: [FileNode] = []
        func collect(_ nodes: [FileNode]) {
            for node in nodes {
                guard let children = node.children else { continue }
                loaded.append(node)
                collect(children)
            }
        }
        collect(roots)
        return loaded
    }

    func applyingChanges(_ body: () -> Void) {
        changeDepth += 1
        defer { changeDepth -= 1 }
        body()
    }
}

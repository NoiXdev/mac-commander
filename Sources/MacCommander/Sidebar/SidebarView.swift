import AppKit
import MacCommanderCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    let model: BrowserModel
    @Environment(FavoritesStore.self) private var favorites
    private let volumesState = State(initialValue: VolumeProvider.localVolumes())
    private let missingState = State<SidebarLocation?>(initialValue: nil)
    private var volumes: [VolumeInfo] {
        get { volumesState.wrappedValue }
        nonmutating set { volumesState.wrappedValue = newValue }
    }
    private var missing: SidebarLocation? {
        get { missingState.wrappedValue }
        nonmutating set { missingState.wrappedValue = newValue }
    }

    var body: some View {
        List {
            Section(String(localized: "Favorites")) {
                ForEach(favorites.favorites) { location in
                    row(name: location.name, url: location.url, exists: location.exists)
                        .onTapGesture { select(location) }
                        .contextMenu {
                            Button(String(localized: "Remove from Sidebar")) { favorites.remove(location.url) }
                        }
                }
                .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                .onInsert(of: [.fileURL]) { index, providers in drop(providers, at: index) }
            }
            Section(String(localized: "Locations")) {
                ForEach(volumes) { volume in
                    HStack {
                        row(name: volume.name, url: volume.url, exists: true, symbol: volume.isBoot ? "internaldrive" : "externaldrive")
                        if volume.isEjectable {
                            Button {
                                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                            } label: {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Eject"))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.navigate(to: volume.url) } }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { favorites.refreshExistence() }
        .task { await observeVolumes() }
        .alert(
            String(localized: "“\(missing?.name ?? "")” can't be found. Remove it from Favorites?"),
            isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })
        ) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let missing { favorites.remove(missing.url) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private func row(name: String, url: URL, exists: Bool, symbol: String? = nil) -> some View {
        Label(name, systemImage: symbol ?? Self.symbol(for: url))
            .foregroundStyle(exists ? Color.primary : Color.secondary)
            .opacity(exists ? 1 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func select(_ location: SidebarLocation) {
        favorites.refreshExistence()
        if FileManager.default.fileExists(atPath: location.url.path) {
            Task { await model.navigate(to: location.url) }
        } else {
            missing = location
        }
    }

    private func drop(_ providers: [NSItemProvider], at index: Int) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return }
                Task { @MainActor in favorites.add(url, at: index) }
            }
        }
    }

    private func observeVolumes() async {
        let center = NSWorkspace.shared.notificationCenter
        let names = VolumeProvider.didChangeNotifications
        let stream = AsyncStream<Void> { continuation in
            let tokens = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield() }
            }
            let box = TokenBox(tokens)
            continuation.onTermination = { _ in box.tokens.forEach { center.removeObserver($0) } }
        }
        for await _ in stream { volumes = VolumeProvider.localVolumes() }
    }

    private static func symbol(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.standardizedFileURL.path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "square.grid.2x2"
        default: return "folder"
        }
    }
}

/// Carries notification tokens into a `@Sendable` termination handler.
private final class TokenBox: @unchecked Sendable {
    // @unchecked: immutable after init, and only used to remove observers (thread-safe).
    let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
}

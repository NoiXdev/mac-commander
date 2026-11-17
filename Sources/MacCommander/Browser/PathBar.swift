import AppKit
import MacCommanderCore
import SwiftUI

/// Clickable breadcrumb of the current folder.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        let segments = PathUtilities.segments(of: model.currentURL)
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
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
}

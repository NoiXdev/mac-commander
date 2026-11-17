import AppKit
import SwiftUI

/// The preview panel on the right of the file list: a header for the selected item and its preview.
struct PreviewPane: View {
    let controller: PreviewController

    var body: some View {
        VStack(spacing: 0) {
            if let header = controller.header {
                PreviewHeaderView(header: header)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.content {
        case .empty(let text):
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        case .quickLook(let url):
            QuickLookPreview(url: url)
        case .rendered(let rendered, _):
            // Interim until the web view (Task 5): the renderer's source text.
            SourceTextView(text: rendered.source ?? "")
        case .source(let text, _):
            SourceTextView(text: text)
        case .message(let text, let actions):
            VStack(spacing: 12) {
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ForEach(actions, id: \.title) { action in
                    Button(action.title) { controller.perform(action) }
                }
            }
            .padding()
        }
    }
}

private struct PreviewHeaderView: View {
    let header: PreviewHeader

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: header.icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(header.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !header.detail.isEmpty {
                    Text(header.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let modified = header.modified {
                    Text(modified)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

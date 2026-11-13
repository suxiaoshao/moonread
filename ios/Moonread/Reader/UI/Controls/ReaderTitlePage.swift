import SwiftUI

/// The in-book title page shares the shelf's type and palette, with room to
/// breathe at reading size. It never contributes characters to the novel.
struct ReaderTitlePage: View {
    let title: String
    var information: ReaderCoverInformation? = nil
    var contentSHA256: String? = nil
    var showDetails: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                BookCoverView(title: title, cover: information?.cover, contentSHA256: information?.sha ?? contentSHA256, author: information?.author)
                    .frame(width: 70, height: 100).accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                    .foregroundStyle(Color(uiColor: theme.ink))
                    .multilineTextAlignment(.center)
                    .lineLimit(6).minimumScaleFactor(0.65)
                    .padding(.top, 32)
                    .padding(.horizontal, 32)
                Rectangle().fill(Color(uiColor: theme.accent).opacity(0.45))
                    .frame(width: 32, height: 1).padding(.top, 28)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    if let author = information?.author, !author.isEmpty { Text(verbatim: author).lineLimit(1) }
                    if let information = information?.details {
                        if let body = information.body, body.wordCount > 0 { Text("\(body.wordCount) 字 · \(body.chapterCount) 章").lineLimit(1) }
                        if !information.metadata.tags.isEmpty { Text(verbatim: information.metadata.tags.prefix(3).joined(separator: " · ")).lineLimit(1) }
                        if !information.metadata.synopsis.isEmpty { Text(verbatim: information.metadata.synopsis).lineLimit(2) }
                    }
                    if let showDetails { Button("小说详情", action: showDetails).frame(minHeight: 44).accessibilityIdentifier("coverBookDetails") }
                }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    .multilineTextAlignment(.center).padding(.horizontal, 32).frame(height: 148, alignment: .top).padding(.top, 20)
                Spacer(minLength: 32)
                Text("月读").font(.caption).tracking(4)
                    .foregroundStyle(Color(uiColor: theme.secondary)).padding(.bottom, 36)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "封面，\(title)"))
            .accessibilityIdentifier("readerCover")
    }
}

import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI

public struct BookInformationSections<Cover: View>: View {
    let model: BookInformationModel
    let target: BookInformationTarget
    let title: String
    let openSource: ((LibraryEntry) -> Void)?
    let openCached: ((String) -> Void)?
    let showAuthor: ((String) -> Void)?
    let showTag: ((String) -> Void)?
    let cover: (String, BookMetadata?) -> Cover

    public init(model: BookInformationModel, target: BookInformationTarget, title: String,
                openSource: ((LibraryEntry) -> Void)?, openCached: ((String) -> Void)?,
                showAuthor: ((String) -> Void)?, showTag: ((String) -> Void)?,
                @ViewBuilder cover: @escaping (String, BookMetadata?) -> Cover) {
        self.model = model
        self.target = target
        self.title = title
        self.openSource = openSource
        self.openCached = openCached
        self.showAuthor = showAuthor
        self.showTag = showTag
        self.cover = cover
    }
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    /// Reading is the page's main task: one full-width prominent action under the book identity.
    @ViewBuilder private var primaryAction: some View {
        if target.fromReader {
            Button { dismiss() } label: { Text("返回阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let entry = model.entry, let openSource {
            Button {
                let metadata = model.details?.metadata
                openSource(entry.withMetadata(metadata?.sha == entry.readingIdentity?.formalSHA256 ? metadata : nil))
            } label: { Text(entry.lastRead == 0 ? "开始阅读" : "继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        } else if let book = model.readableBook, let openCached {
            Button { openCached(book.id) } label: { Text("继续阅读").frame(maxWidth: .infinity) }
                .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
        }
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                cover(model.entry?.title ?? title, model.details?.metadata)
                    .frame(width: 64, height: 90).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.entry?.title ?? title)
                        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    author
                    bookCounts.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.accessibilityIdentifier("bookInformationHeader")
            primaryAction
            if let tags = model.details?.metadata.tags, !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { showTag?(tag) }
                            .font(.subheadline).buttonStyle(.bordered)
                            .disabled(showTag == nil)
                    }
                }
            }
            if let synopsis = model.details?.metadata.synopsis, !synopsis.isEmpty {
                BookSynopsis(synopsis: synopsis).id(synopsis)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("我的阅读").font(.headline)
                readingCard
            }.id("myReading")
        }.frame(maxWidth: .infinity, alignment: .leading).id("bookInformation")
    }
    @ViewBuilder private var author: some View {
        if let author = model.details?.metadata.author, !author.isEmpty {
            if let showAuthor {
                Button { showAuthor(author) } label: {
                    let arrow = Text(Image(systemName: "chevron.right")).font(.caption.weight(.semibold))
                    Text("\(Text(verbatim: author)) \(arrow)")
                        .accessibilityLabel(Text(verbatim: author))
                }
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
            } else { Text(verbatim: author) }
        }
    }
    @ViewBuilder private var bookCounts: some View {
        if let body = model.details?.body, body.wordCount > 0 {
            let style = IntegerFormatStyle<UInt64>.number.locale(locale)
            let count = body.wordCount < 10_000
                ? body.wordCount.formatted(style)
                : body.wordCount.formatted(style.notation(.compactName).precision(.fractionLength(0)))
            Text("\(count) 字 · \(body.chapterCount) 章")
                .accessibilityLabel(Text("\(body.wordCount) 字 · \(body.chapterCount) 章"))
        }
    }
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let details = model.details {
                let position = model.entry?.positionUtf8 ?? details.book?.positionUtf8 ?? 0
                let bytes = model.entry?.byteCount ?? details.book?.byteCount ?? 0
                HStack(alignment: .top, spacing: 12) {
                    if let chapter = details.currentChapter { Text(verbatim: chapter).font(.body).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0)
                    Picker("阅读状态", selection: Binding(get: { details.metadata.status }, set: { value in Task { await model.setStatus(value) } })) {
                        if case .other = details.metadata.status { Text(details.metadata.status.label).tag(details.metadata.status) }
                        if details.metadata.status == .unread { Text("未读").tag(BookReadingStatus.unread) }
                        ForEach([BookReadingStatus.reading, .finished, .paused], id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("bookReadingStatus")
                }
                if bytes > 0 {
                    let fraction = ReadingProgress.fraction(position, of: bytes)
                    let positionLabel = Text("读到全书 \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                    ProgressView(value: fraction).accessibilityLabel("全书位置")
                    ViewThatFits(in: .horizontal) {
                        HStack { positionLabel; Spacer(); coverageLabel(position) }
                        VStack(alignment: .leading, spacing: 6) { positionLabel; coverageLabel(position) }
                    }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                } else { coverageLabel(position).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            if let error = model.error, model.details == nil {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                Button("重试") { model.retryInformation() }
            } else if model.matches(target), model.contentSHA(for: target) == nil {
                Text("阅读位置暂不可用").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            } else if model.details == nil { ProgressView() }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            .task(id: model.details == nil ? nil : model.readableBook?.id) {
                model.releaseCoverage()
                if model.details != nil, let id = model.readableBook?.id { await model.observeCoverage(bookID: id) }
            }
            .onDisappear { model.releaseCoverage() }
    }
    private func coverageLabel(_ position: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本章覆盖 \(model.chapters.last(where: { $0.startUtf8 <= position })?.coverageLabel(readingPrefix: false) ?? "—")")
            if let error = model.coverageError { Text(verbatim: error).font(.caption) }
        }
    }
}

private struct BookSynopsis: View {
    let synopsis: String
    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > previewHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if overflows {
                DisclosureGroup(isExpanded: $expanded) {
                    EmptyView()
                } label: {
                    Text("简介").font(.headline).foregroundStyle(Color(uiColor: theme.ink)).frame(minHeight: LayoutTokens.hit, alignment: .leading)
                }
            }
            synopsisText(limit: overflows && expanded ? nil : 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                synopsisText()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
                synopsisText(limit: 3)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { previewHeight = $0 }
            }.hidden().accessibilityHidden(true)
        }
    }

    private func synopsisText(limit: Int? = nil) -> some View {
        Text(verbatim: synopsis).font(.body).lineLimit(limit)
            .foregroundStyle(Color(uiColor: theme.ink))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

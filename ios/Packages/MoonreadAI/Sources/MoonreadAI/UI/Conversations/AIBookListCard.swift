import MoonreadData
import MoonreadDesign
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI

public struct AIBookListCard: View {
    public init(owner: String, books: [AIBookListPresentation], readingAccess: AIReadingAccess,
                readingInputRevision: @escaping @MainActor () -> UInt64, openBook: @escaping (String, String, LibraryEntry) -> Void) {
        self.owner = owner; self.books = books; self.readingAccess = readingAccess
        self.readingInputRevision = readingInputRevision; self.openBook = openBook
    }
    public let owner: String
    public let books: [AIBookListPresentation]
    private let readingAccess: AIReadingAccess
    private let readingInputRevision: @MainActor () -> UInt64
    private let openBook: (String, String, LibraryEntry) -> Void
    @Environment(\.theme) private var theme
    @State private var unavailable: Set<String> = []
    @State private var openFailed = false
    @State private var opening = false

    private var refs: [String] { books.map(\.id) }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Label("书单 · \(books.count) 本", systemImage: "books.vertical")
                .font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                ForEach(books) { item in
                    if item.id != books.first?.id {
                        Divider().overlay(Color(uiColor: theme.separator)).padding(.leading, BookFileRowLayout.textLeading)
                    }
                    if unavailable.contains(item.id) {
                        row(item, missing: true)
                    } else {
                        Button {
                            guard !opening else { return }
                            opening = true
                            Task { await open(item) }
                        } label: {
                            row(item, missing: false)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutTokens.content)
        .background(Color(uiColor: theme.raised), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutTokens.inputRadius)
                .strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border)
                .allowsHitTesting(false)
        }
        .task(id: readingInputRevision()) { _ = try? await refresh() }
        .alert("暂时无法打开这本书", isPresented: $openFailed) {
            Button("好", role: .cancel) {}
        }
    }

    private func row(_ item: AIBookListPresentation, missing: Bool) -> some View {
        BookFileRowContent(title: Text(verbatim: item.book.title),
                               author: item.book.author.map { Text(verbatim: $0) }, unavailable: missing) {
            AIBookListCover(owner: owner, item: item)
                .saturation(missing ? 0 : 1)
        } status: {
            Group {
                if missing { Text("书库中已没有这本书") }
                else { Text(verbatim: ReadingProgressLabel.text(needsDownload: item.needsDownload, fraction: item.progress)).lineLimit(1) }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func refresh() async throws -> AIBookListResolution {
        let result = try await readingAccess.aiBookListEntries(refs, false)
        try Task.checkCancellation()
        unavailable = Set(refs).subtracting(result.entries.keys)
        return result
    }

    private func open(_ item: AIBookListPresentation) async {
        defer { opening = false }
        do {
            guard let entry = try await refresh().entries[item.id] else { return }
            openBook(item.id, item.book.title, entry)
        } catch is CancellationError {
            return
        } catch {
            openFailed = true
        }
    }
}

private struct AIBookListCover: View {
    let owner: String
    let item: AIBookListPresentation
    @State private var image: UIImage?

    var body: some View {
        MetadataCoverPreview(title: item.book.title, image: image, contentSHA256: item.coverSeed,
                             author: item.book.author, compact: true)
            .task(id: item.thumbnail) {
                image = nil
                guard let ref = item.thumbnail,
                      let bytes = try? await AIImageStore.shared.read(owner: owner, ref: ref),
                      !Task.isCancelled else { return }
                image = UIImage(data: bytes)
            }
    }
}

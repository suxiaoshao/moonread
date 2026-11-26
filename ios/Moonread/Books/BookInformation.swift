import MoonreadDesign
import MoonreadData
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers

extension BookInformationModel {
    convenience init(
        service: AppDataService = .shared,
        readInformation: (@MainActor (BookInformationTarget) async throws -> (LibraryEntry?, BookDetailsResult))? = nil,
        readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil
    ) {
        self.init(source: .init(
            read: readInformation ?? {
                try await service.bookInformation($0.target, fileID: $0.fileID, includeRecordSource: !$0.fromReader)
            },
            readChapters: readChapters,
            updates: {
                try await service.bookInformationUpdates($0.target, fileID: $0.fileID, includeRecordSource: !$0.fromReader)
            },
            observeCoverage: { try await service.observeChapterCoverage($0, receive: $1) },
            prepareMetadata: { try await prepareBookMetadata(service: service, source: $0, cachedBookID: $1, progress: $2) },
            makeDraft: { base in
                .init(base: base, makeCover: { try await service.makeCover($0) },
                      discardCover: { await service.discardCoverDraft($0) }, describeError: { ReaderMessages.error($0) })
            },
            saveMetadata: { try await service.saveMetadata(base: $0, edited: $1) },
            details: { try await service.bookDetails($0) },
            observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) },
            describeError: { ReaderMessages.error($0) }
        ))
    }
}

@MainActor
private func prepareBookMetadata(
    service: AppDataService,
    source: SourceFile?, cachedBookID: String?,
    progress: @escaping BookInformationSource.Progress
) async throws -> BookDetailsResult {
    let lease: ReadingLease
    if let source {
        try await service.prepareSourceFile(source) { value in
            Task { @MainActor in progress(.downloading, value) }
        }
        try Task.checkCancellation()
        progress(.indexing, nil)
        lease = try await service.openSourceFile(source)
    } else if let id = cachedBookID {
        lease = try await service.openReading(id)
    } else { throw ReaderError.NotFound }
    while true {
        try Task.checkCancellation()
        let snapshot = try await service.snapshot(lease.id)
        if snapshot.preparation.isComplete {
            let result = try await service.bookDetails(.cached(bookId: lease.id))
            _ = try result.requireIdentified()
            return result
        }
        if snapshot.preparation.isFailed { throw CocoaError(.fileReadCorruptFile) }
        if snapshot.preparation.isPaused {
            try Task.checkCancellation()
            try await service.resumeImport(lease.id)
        }
        progress(.indexing, snapshot.byteProgress.total > 0 ? Double(snapshot.byteProgress.read) / Double(snapshot.byteProgress.total) : nil)
        try await Task.sleep(for: .milliseconds(100))
    }
}

struct HostedBookInformation: View {
    let model: BookInformationModel
    let target: StatisticsRoute
    let library: LibraryModel
    let host: LibraryBrowsingHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.returnToReading) private var returnToReading
    @State private var readerDestination: LibraryRoute?

    private func navigate(_ route: LibraryRoute) {
        if target.fromReader { readerDestination = route }
        else { host.navigate(route, in: library) }
    }

    var body: some View {
        BookInformationSections(
            model: model, target: target.informationTarget, title: target.title,
            openSource: { host.open($0, in: library) },
            openCached: { host.navigate(.reader(OpeningRequest(target: .book($0))), in: library) },
            showAuthor: { navigate(.author(.init($0))) },
            showTag: { navigate(.search(.init(seeds: [.tag($0)]))) }
        ) { title, metadata in
            BookCoverView(title: title, cover: metadata?.cover, contentSHA256: metadata?.sha, author: metadata?.author)
        }
        .navigationDestination(item: $readerDestination) { route in
            HostedLibraryDestination(route: route, host: .init(allowsFileBrowsing: false, isOpenBook: { entry in
                entry.id == target.fileID || model.contentSHA(for: target.informationTarget).map { entry.readingKey == $0 } == true
            }, returnToOpenBook: {
                if let returnToReading { returnToReading() } else { dismiss() }
            }))
        }
    }
}

struct BookReadingDataClearSection: View {
    @Environment(\.theme) private var theme
    let book: BookInformationModel
    let target: StatisticsRoute
    let key: String
    @Bindable var manager: DataManagementModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                Task {
                    if !target.fromReader { await book.finishPreparationForDataDeletion() }
                    await manager.load()
                    manager.requestDelete([key])
                }
            } label: {
                Text("清除本书阅读数据").frame(maxWidth: .infinity)
            }
                .buttonStyle(.bordered).tint(Color(uiColor: theme.destructive)).foregroundStyle(Color(uiColor: theme.destructive))
                .disabled(manager.busy).accessibilityIdentifier("clearBookReadingData")
            if let message = manager.message { Text(verbatim: message).font(.footnote) }
        }.padding(.top, 8)
            .modifier(ReadingDataDeletionPrompt(model: manager))
            .onChange(of: manager.busy) { _, busy in if !busy { Task { await book.load(target.informationTarget) } } }
            .alert("暂时无法完成", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.clearError() } })) {
                Button("知道了", role: .cancel) { manager.clearError() }
            } message: { Text(manager.error ?? "") }
    }
}

extension View {
    func metadataCoverPresentation() -> some View {
        environment(\.metadataCoverRenderer) { request in
            AnyView(BookCoverView(title: request.title, compact: request.compact, cover: request.cover,
                                  contentSHA256: request.contentSHA256, author: request.author,
                                  pixels: request.pixels, contentMode: request.contentMode))
        }
    }
}

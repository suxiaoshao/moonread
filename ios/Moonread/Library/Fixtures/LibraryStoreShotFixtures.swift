import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

#if DEBUG
import WidgetKit
#endif

#if DEBUG
extension AppDataService {
    func createLocalizedStoreShotFixture() async throws {
        guard let capture = StoreShotCapture.requested else { throw ReaderError.InvalidSettings }
        let f = try StoreShotFixture.localized(capture.language)
        let scene = StoreShotScene.scene(for: capture)
        let books = f.books(for: scene)
        let bookIndices = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.title, $0.offset) })
        guard let session = testSession, libraryDirectoryOverride != nil, cloudLibraryRoot == nil else { throw LibraryFileError.invalidDestination }
        let root = try builtinLibraryURL().resolvingSymlinksInPath(), temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard root.path.hasPrefix(temp.path + "/"), root.lastPathComponent == "Moonread-StoreShots-" + session,
              !root.path.contains("Mobile Documents"), !root.path.contains("CloudDocs"), !root.pathComponents.contains("Downloads") else { throw LibraryFileError.invalidDestination }
        var settings = defaultReaderSettings(); settings.font = .system; settings.mode = .scroll
        // Save the ordinary reader preference; no display/font scaling override.
        settings.fontSize = capture.fontSize
        if capture.paged { settings.mode = .pages }
        try saveSettings(settings)
        guard !sourceDefaults.bool(forKey: "StoreShots.seeded") else { return }
        for folder in f.folders { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for (index, book) in books.enumerated() {
            let parent = index == 3 || index == 4 ? root.appendingPathComponent(f.folders[0]) : (index == 5 ? root.appendingPathComponent(f.folders[1]) : root)
            let url = parent.appendingPathComponent(book.title + ".txt")
            try book.text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Self.storeShotDate(rank: index)], ofItemAtPath: url.path)
        }
        // Unread directories fall back to modification time. Set it after writing their files.
        for (index, folder) in f.folders.enumerated() {
            try FileManager.default.setAttributes([.modificationDate: Self.storeShotDate(rank: books.count + index)],
                                                  ofItemAtPath: root.appendingPathComponent(folder).path)
        }
        try refreshLibraryShelf("builtin")
        let core = try indexStore()
        let files = try core.sourceFileSnapshots(fileId: nil).filter { $0.shelfId == "builtin" }
        for file in files {
            let path = root.appendingPathComponent(file.relativePath)
            let title = path.deletingPathExtension().lastPathComponent
            let entry = try await libraryEntry(file.id)
            let prepared = try await aiPrepare(entry.source)
            let book = try await snapshot(prepared.id).book
            defer { withExtendedLifetime(prepared) {} }
            guard let index = bookIndices[title] else { throw ReaderError.InvalidRange }
            if (1...2).contains(index) {
                let text = books[index].text
                guard let range = text.range(of: f.progressChapters[index - 1]) else { throw ReaderError.InvalidRange }
                let offset = UInt64(text[..<range.lowerBound].utf8.count)
                try await savePosition(bookID: book.id, offset: offset, at: Self.storeShotMilliseconds(rank: index))
                if index == 1, scene == .author {
                    try await createStoreShotStatistics(bookID: book.id, dailyMinutes: [0, 0, 0, 0, 0, 12, 0])
                }
            } else if index >= f.books.count, scene == .resumeHome || scene == .author {
                // Actual resume positions give the additional books a fixed recent order.
                let text = books[index].text
                guard let start = text.range(of: "\n\n")?.upperBound else { throw ReaderError.InvalidRange }
                try await savePosition(bookID: book.id, offset: UInt64(text[..<start].utf8.count),
                                       at: Self.storeShotMilliseconds(rank: index))
            }
            let metadata = try await details(bookID: book.id).metadata
            var edited = metadata
            // The author scene shows the same works in every language, all with a fixed resume position.
            if scene != .author || index < 3 || index >= f.books.count { edited.author = f.author }
            if index < f.books.count {
                edited.tags = [index == 3 || index == 5 ? f.folders[1] : f.folders[0]]
            }
            try await saveMetadata(base: metadata, edited: edited)
            if title == f.books[0].title {
                let original = f.books[0].text
                for pair in (scene.map { [StoreShotScene.paper, .mint, .bamboo, .listening].contains($0) } == true ? [] : f.notes) {
                    guard let range = original.range(of: pair[0]) else { throw ReaderError.InvalidRange }
                    let start = UInt64(original[..<range.lowerBound].utf8.count), end = start + UInt64(pair[0].utf8.count)
                    let edit = try await prepareAnnotation(book.id, start: start, end: end)
                    _ = try await saveNote(edit, text: pair[1])
                }
                guard let range = original.range(of: f.bookmark) else { throw ReaderError.InvalidRange }
                _ = try await ensureBookmark(book.id, at: UInt64(original[..<range.lowerBound].utf8.count))
                if StoreShotPage.requested != nil {
                    try await savePosition(bookID: book.id, offset: UInt64(original[..<range.lowerBound].utf8.count),
                                           at: Self.storeShotMilliseconds(rank: index))
                    var display = edited
                    display.synopsis = original.components(separatedBy: "\n\n").first(where: { $0.count > 45 }) ?? ""
                    try await saveMetadata(base: edited, edited: display)
                }
                if let scene {
                    let chapter = original.range(of: f.mainChapters[1])!
                    var start = chapter.lowerBound
                    if scene == .annotation, let note = original.range(of: f.notes[0][0]) {
                        // Restore at the start of the highlighted paragraph so
                        // the runner can tap its actual rendered text.
                        start = original[..<note.lowerBound].range(of: "\n\n", options: .backwards)?.upperBound ?? original.startIndex
                    }
                    if scene == .recap {
                        start = original.index(original.range(of: f.mainChapters[2])!.lowerBound, offsetBy: -2)
                    }
                    var offset = UInt64(original[..<start].utf8.count)
                    if scene == .listening { offset = try f.listeningCue().anchor }
                    if scene == .widget {
                        // A synthetic resume point, not a second progress rule.
                        // The widget percentage/chapter is queried below through Rust.
                        var point = original.utf8.index(original.utf8.startIndex, offsetBy: original.utf8.count * 42 / 100)
                        while String.Index(point, within: original) == nil { point = original.utf8.index(before: point) }
                        offset = UInt64(original.utf8.distance(from: original.utf8.startIndex, to: point))
                    }
                    try await savePosition(bookID: book.id, offset: offset, at: Self.storeShotMilliseconds(rank: index))
                    if scene == .continuation {
                        let ahead = original.range(of: f.mainChapters[2])!.lowerBound
                        let winner = PositionValue(content_key: book.readingKey.storageKey,
                                                   offset: UInt64(original[..<ahead].utf8.count))
                        // Same persisted candidate path as sync, without changing
                        // this device's just-written local resume baseline.
                        let json = String(decoding: try JSONEncoder().encode(winner), as: UTF8.self)
                        try writeFixtureValue("position/" + book.readingKey.storageKey, value: json, device: "store-shot-other-device")
                        dataChanged()
                    }
                    if scene == .statistics || scene == .author || scene == .storageOverview {
                        try await createStoreShotStatistics(bookID: book.id)
                    }
                    if scene == .widget {
                        try await publishStoreShotWidget(book: book, fixture: f)
                    }
                }
            }
        }
        // Use the final decoding after preparation for the fixture shelf's identity index.
        for file in try core.sourceFileSnapshots(fileId: nil).filter({ $0.shelfId == "builtin" }) {
            try registerStoreShotIdentity(file, root: root, core: core)
        }
        guard try core.libraryIdentityInventory(shelfId: "builtin").pending.isEmpty else { throw ReaderError.InvalidRange }
        let inventory = try await readingDataInventory()
        guard inventory.items.count == books.count, inventory.pending == 0, inventory.unsupported == 0,
              try core.libraryShelves().count == 1 else { throw ReaderError.InvalidRange }
        if scene == .resumeHome,
           let id = try core.sourceFiles(shelfId: "builtin").first(where: { $0.relativePath == f.books[0].title + ".txt" })?.bookId {
            try await recordBookOpened(id, at: Self.storeShotMilliseconds(rank: 0))
        }
        if StoreShotPage.requested != nil,
           let id = try core.sourceFiles(shelfId: "builtin").first(where: { $0.relativePath == f.books[0].title + ".txt" })?.bookId {
            try await createStatisticsFixture(bookID: id)
        }
        let preferences = try decodeThemePreferences(json: sourceDefaults.string(forKey: "Moonread.themePreferences")!)
        var snapshot = defaultThemeSnapshot(); snapshot.preferences = preferences
        let resolved = try resolveThemes(value: snapshot, system: capture.systemAppearance == "dark" ? .dark : .light, highContrast: false)
        let receipt: [String: Any] = ["id": capture.id, "fixtureVersion": capture.fixtureVersion,
            "appPalette": resolved.app.paletteId, "readerPalette": resolved.reader.paletteId,
            "readerAppearance": resolved.reader.appearance == .dark ? "dark" : "light",
            "readerTextureEnabled": resolved.readerTexture.enabled,
            "fontSize": settings.fontSize, "font": "system", "readingMode": capture.paged ? "pages" : "scroll",
            "language": capture.language, "locale": capture.locale, "storefront": capture.storefront,
            "libraryCount": inventory.items.count, "pendingCount": inventory.pending, "unsupportedCount": inventory.unsupported,
            "library_root": "tmp/" + root.lastPathComponent,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("StoreScreenshots-fixture.json"), options: .atomic)
        sourceDefaults.set(true, forKey: "StoreShots.seeded")
    }

    private static func storeShotDate(rank: Int) -> Date {
        StoreShotScene.statisticsDate.addingTimeInterval(-Double(rank) * 3_600)
    }

    private static func storeShotMilliseconds(rank: Int) -> Int64 {
        Int64(storeShotDate(rank: rank).timeIntervalSince1970 * 1_000)
    }

    func makeStoreShotBackupReview(_ fixture: StoreShotFixture) async throws -> URL {
        let inventory = try await readingDataInventory()
        let core = try indexStore()
        guard let missing = inventory.items.first(where: { $0.title == fixture.books[1].title }),
              let newer = inventory.items.first(where: { $0.title == fixture.books[4].title }),
              let missingSource = try core.sourceFilesForSha(sha: missing.id).first,
              let newerSource = try core.sourceFilesForSha(sha: newer.id).first else {
            throw ReaderError.NotFound
        }
        let url = try await exportReadingData()
        _ = try await deleteReadingData([missing.id, newer.id], configuration: inventory.configuration)
        let root = try builtinLibraryURL()
        for source in [missingSource, newerSource] {
            guard let file = try core.sourceFileSnapshots(fileId: source.id).first else { throw ReaderError.NotFound }
            try registerStoreShotIdentity(file, root: root, core: core)
        }
        let base = try await details(sha: newer.id).metadata
        var edited = base
        edited.author = fixture.author
        edited.tags = [fixture.folders[1]]
        try await saveMetadata(base: base, edited: edited)
        return url
    }

    private func registerStoreShotIdentity(_ file: SourceFileSnapshot, root: URL, core: ReaderIndex) throws {
        let url = root.appendingPathComponent(file.relativePath)
        let identity = try SourceIdentityProbe().identify(filePath: url.path, decoding: file.decoding)
        guard try core.publishSourceIdentity(file: file, identity: identity) else {
            throw ReaderError.SourceChanged
        }
    }

    private func createStoreShotStatistics(bookID: String, dailyMinutes: [Int] = [18, 0, 28, 36, 45, 39, 32]) async throws {
        // Frozen original sample, using the same clock and writer as reading.
        for (index, minutes) in dailyMinutes.enumerated() where minutes > 0 {
            let day = Calendar.current.date(byAdding: .day, value: index - 6, to: StoreShotScene.statisticsDate)!
            let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
            let clock = ReadingClock(bookId: bookID)
            var point = ReadingMoment(monotonicMs: 0, unixMs: Int64(start.timeIntervalSince1970 * 1000),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: start)), readable: true,
                interaction: true, automaticMoving: false, automaticMilliseconds: 0, preview: false, startUtf8: 0, endUtf8: 30)
            _ = clock.update(moment: point)
            for minute in 1...minutes {
                point.monotonicMs = UInt64(minute * 60_000)
                point.unixMs = Int64(start.timeIntervalSince1970 * 1000) + Int64(minute * 60_000)
                point.readable = minute != minutes
                try await saveReading(clock.update(moment: point), generation: statisticsPreferences().generation)
            }
        }
    }

    private func publishStoreShotWidget(book: BookInfo, fixture: StoreShotFixture) async throws {
        #if targetEnvironment(simulator)
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SystemReadingSnapshotFile.groupIdentifier) else {
            throw LibraryFileError.invalidDestination
        }
        guard let sha = book.readingKey.formalSHA256 else { throw ReaderError.NotFound }
        let id = try SystemReadingBookID(sha: sha).rawValue
        guard let projected = try await systemBookCatalogue().systemBookCatalogue.first(where: { $0.readingKey == sha })
        else { throw ReaderError.NotFound }
        let entry = SystemReadingSnapshot.Book(id: id, title: book.title, author: fixture.author, tags: [],
            availability: .available, sourceCount: 1, naturalOrdinal: 0, progress: projected.percentage,
            chapterLabel: projected.chapterTitle, recentRank: 0, allowsAutomaticExposure: true)
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("StoreScreenshots", isDirectory: true))
        let scope = "synthetic-store-screenshots", appearance = await systemWidgetAppearance()
        try file.publish(.init(storeScope: scope, books: [entry], recentIDs: [id], appearance: appearance))
        try file.publishStatistics(.init(storeScope: scope, appearance: appearance, statistics: try await systemWidgetStatistics()))
        UserDefaults(suiteName: SystemReadingSnapshotFile.groupIdentifier)?.set(fixture.language, forKey: "StoreScreenshots.language")
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        #endif
    }
}

extension StoreShotFixture {
    var storeShotSavedShelf: SavedFilter {
        let name = language == "en" ? "Stories to read" : language == "zh-Hant" ? "想讀的故事" : "想读的故事"
        return SavedFilter(id: UUID(), name: name, configuration: storeShotSearch)
    }

    var storeShotSearch: BookSearchConfiguration {
        var configuration = BookSearchConfiguration()
        configuration.root.children = [AppSearchSeed.tag(folders[0]).node]
        configuration.sorts = [.init(field: .recent, descending: true)]
        return configuration
    }
}

extension ReaderSession {
    func showStoreShotListening() {
        guard StoreShotScene.requested == .listening, let capture = StoreShotCapture.requested,
              let fixture = try? StoreShotFixture.localized(capture.language), book?.title == fixture.books.first?.title,
              let cue = try? fixture.listeningCue(), let window,
              cue.sentence.lowerBound >= window.start, cue.sentence.upperBound <= window.end else { return }
        toolsSession.send(.openListening)
        activeListening?.showStoreShot(sentence: .init(startUtf8: cue.sentence.lowerBound, endUtf8: cue.sentence.upperBound))
    }
}
#endif

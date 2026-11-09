import Foundation

#if DEBUG
import WidgetKit
#endif

#if DEBUG
extension AppDataService {
    func createLocalizedStoreShotFixture() async throws {
        guard let capture = StoreShotCapture.requested else { throw ReaderError.InvalidSettings }
        let f = try StoreShotFixture.localized(capture.language)
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
        for (index,book) in f.books.enumerated() {
            let parent = index == 3 || index == 4 ? root.appendingPathComponent(f.folders[0]) : (index == 5 ? root.appendingPathComponent(f.folders[1]) : root)
            try book.text.write(to: parent.appendingPathComponent(book.title + ".txt"), atomically: true, encoding: .utf8)
        }
        try refreshLibraryShelf("builtin")
        let core = try textCore()
        let files = try core.sourceFileSnapshots(fileId: nil).filter { $0.shelfId == "builtin" }
        for file in files {
            let path = root.appendingPathComponent(file.relativePath)
            let identity = try SourceIdentityProbe().identify(filePath: path.path, decoding: file.decoding)
            guard try core.publishSourceIdentity(file: file, identity: identity) else { throw ReaderError.InvalidRange }
            let title = path.deletingPathExtension().lastPathComponent
            let book = try core.importBook(filePath: path.path, title: title)
            try core.linkLibraryFile(fileId: file.id, bookId: book.id)
            if let index = [f.books[1].title, f.books[2].title].firstIndex(of: title) {
                guard let range = f.books[index + 1].text.range(of: f.progressChapters[index]) else { throw ReaderError.InvalidRange }
                let offset = UInt64(f.books[index + 1].text[..<range.lowerBound].utf8.count)
                try await savePosition(bookID: book.id, offset: offset)
            }
            let metadata = try await details(bookID: book.id).metadata
            var edited = metadata; edited.author = f.author; edited.tags = [title == f.books[3].title || title == f.books[5].title ? f.folders[1] : f.folders[0]]
            try await saveMetadata(base: metadata, edited: edited)
            if title == f.books[0].title {
                let original = f.books[0].text
                for pair in (StoreShotScene.requested.map { [StoreShotScene.paper, .mint, .bamboo].contains($0) } == true ? [] : f.notes) {
                    guard let range = original.range(of: pair[0]) else { throw ReaderError.InvalidRange }
                    let start = UInt64(original[..<range.lowerBound].utf8.count), end = start + UInt64(pair[0].utf8.count)
                    let edit = try await prepareAnnotation(book.id, start: start, end: end)
                    _ = try await saveNote(edit, text: pair[1])
                }
                guard let range = original.range(of: f.bookmark) else { throw ReaderError.InvalidRange }
                _ = try await ensureBookmark(book.id, at: UInt64(original[..<range.lowerBound].utf8.count))
                if StoreShotPage.requested != nil {
                    try await savePosition(bookID: book.id, offset: UInt64(original[..<range.lowerBound].utf8.count))
                    var display = edited
                    display.synopsis = original.components(separatedBy: "\n\n").first(where: { $0.count > 45 }) ?? ""
                    try await saveMetadata(base: edited, edited: display)
                }
                if let scene = StoreShotScene.requested {
                    let chapter = original.range(of: f.mainChapters[1])!
                    var start = chapter.lowerBound
                    if scene == .annotation, let note = original.range(of: f.notes[0][0]) {
                        // Start at the preceding paragraph, not an arbitrary
                        // character in a line, keeping complete reading lines.
                        start = original[..<note.lowerBound].dropLast(2)
                            .range(of: "\n\n", options: .backwards)?.upperBound ?? original.startIndex
                    }
                    if scene == .recap {
                        start = original.index(original.range(of: f.mainChapters[2])!.lowerBound, offsetBy: -2)
                    }
                    var offset = UInt64(original[..<start].utf8.count)
                    if scene == .widget {
                        // A synthetic resume point, not a second progress rule.
                        // The widget percentage/chapter is queried below through Rust.
                        var point = original.utf8.index(original.utf8.startIndex, offsetBy: original.utf8.count * 42 / 100)
                        while String.Index(point, within: original) == nil { point = original.utf8.index(before: point) }
                        offset = UInt64(original.utf8.distance(from: original.utf8.startIndex, to: point))
                    }
                    try await savePosition(bookID: book.id, offset: offset)
                    if scene == .continuation {
                        let ahead = original.range(of: f.mainChapters[2])!.lowerBound
                        let winner = PositionValue(content_key: book.contentSha256,
                                                   offset: UInt64(original[..<ahead].utf8.count))
                        // Same persisted candidate path as sync, without changing
                        // this device's just-written local resume baseline.
                        let json = String(decoding: try JSONEncoder().encode(winner), as: UTF8.self)
                        try await userStore().put("position/" + book.contentSha256, value: json, device: "store-shot-other-device")
                        dataChanged()
                    }
                    if scene == .statistics { try await createStoreShotStatistics(bookID: book.id) }
                    if scene == .widget {
                        try await publishStoreShotWidget(book: book, fixture: f)
                    }
                }
            }
        }
        let inventory = try await readingDataInventory()
        guard inventory.items.count == 6, inventory.pending == 0, inventory.unsupported == 0,
              try core.libraryShelves().count == 1 else { throw ReaderError.InvalidRange }
        if StoreShotPage.requested != nil,
           let id = try core.sourceFiles(shelfId: "builtin").first(where: { $0.relativePath == f.books[0].title + ".txt" })?.bookId {
            try await createStatisticsFixture(bookID: id)
        }
        let preferences = try decodeThemePreferences(json: sourceDefaults.string(forKey: "Moonread.themePreferences")!)
        var snapshot = defaultThemeSnapshot(); snapshot.preferences = preferences
        let resolved = try resolveThemes(value: snapshot, system: capture.systemAppearance == "dark" ? .dark : .light, highContrast: false)
        let receipt: [String: Any] = ["id": capture.id, "fixtureVersion": StoreShotCapture.fixtureVersion,
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

    private func createStoreShotStatistics(bookID: String) async throws {
        // Frozen original sample, using the same clock and writer as reading.
        for (index, minutes) in [18, 0, 28, 36, 45, 39, 32].enumerated() where minutes > 0 {
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

    private func publishStoreShotWidget(book: ImportText, fixture: StoreShotFixture) async throws {
        #if targetEnvironment(simulator)
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SystemReadingSnapshotFile.groupIdentifier) else {
            throw LibraryFileError.invalidDestination
        }
        let id = try SystemReadingBookID(sha: book.contentSha256).rawValue
        let query = try await readingQuery(.catalogue(nil, recursive: true), options: .init(scope: "store-shot-widget", sparseCatalogue: true))
        guard let projected = try query.systemReadingCatalogue().first(where: { $0.contentSha256 == book.contentSha256 }) else { throw ReaderError.NotFound }
        let entry = SystemReadingSnapshot.Book(id: id, title: book.title, author: fixture.author, tags: [],
            availability: .available, sourceCount: 1, naturalOrdinal: 0, progress: projected.percentage,
            chapterLabel: projected.chapterTitle, recentRank: 0, allowsAutomaticExposure: true)
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("StoreScreenshots", isDirectory: true))
        try file.publish(.init(storeScope: "synthetic-store-screenshots", books: [entry], recentIDs: [id],
                               appearance: await systemWidgetAppearance()))
        UserDefaults(suiteName: SystemReadingSnapshotFile.groupIdentifier)?.set(fixture.language, forKey: "StoreScreenshots.language")
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        #endif
    }
}
#endif

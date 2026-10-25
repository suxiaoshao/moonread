import Foundation
import XCTest
import SwiftUI
@testable import Moonread

@MainActor final class SystemReadingTests: ReaderIntegrationFixture {
    func testCatalogPublishesAuthoritativeSummaryAndResetsScopeBeforeRebuilding() async throws {
        let (root, service, core, formal, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        let secondSHA = serializeReadingKey(key: try core.resolveBookIdentity(bookId: second.id).key)
        try await formal.put("metadata/" + secondSHA + "/author", value: "\"合成作者\"", device: "test")
        try await service.savePosition(bookID: first.id, offset: 9)
        await service.startSystemReadingCatalog(file: file)
        await service.waitForSystemReadingCatalog()
        let snapshot = try file.read()
        XCTAssertEqual(snapshot.books.count, 2)
        XCTAssertEqual(snapshot.books.first { $0.id == "book:" + secondSHA }?.author, "合成作者")
        let sha = try core.resolveBookIdentity(bookId: first.id).key
        let id = try SystemReadingBookID(sha: serializeReadingKey(key: sha))
        XCTAssertEqual(snapshot.recentIDs.first, id.rawValue)
        XCTAssertNotNil(snapshot.books.first { $0.id == id.rawValue }?.progress)
        let resolved = try await service.resolveSystemReadingBook(id)
        XCTAssertEqual(resolved.readingKey, id.sha)
        let json = String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
        for field in ["relativePath", "bookmark", "utf8Offset", "positionToken", "synopsis"] { XCTAssertFalse(json.contains(field)) }
        XCTAssertTrue(snapshot.exposurePolicy.systemSearchEnabled)
        await service.resetSystemReadingCatalog()
        let empty = try file.read()
        XCTAssertTrue(empty.books.isEmpty); XCTAssertTrue(empty.recentIDs.isEmpty)
        XCTAssertNil(empty.statistics); XCTAssertNil(empty.appearance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.coversDirectory.path))
        XCTAssertNotEqual(empty.storeScope, snapshot.storeScope)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertEqual(try file.read().books.count, 2)
        // User-data deletion clears progress/recency, never the indexed book names.
        try await service.hideRecent(id.sha)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertTrue(try file.read().recentIDs.isEmpty)
        XCTAssertEqual(try file.read().books.count, 2)
    }
    func testSnapshotAtomicPublicationAndUnknownVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root)
        let initial = SystemReadingSnapshot(storeScope: "opaque")
        try file.publish(initial)
        let huge = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "a", count: 64), title: String(repeating: "a", count: 1025), author: nil, tags: [], availability: .available, sourceCount: 1, naturalOrdinal: 0, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: true)
        XCTAssertThrowsError(try file.publish(.init(storeScope: "opaque", books: [huge])))
        XCTAssertEqual(try file.read(), initial)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        raw["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: raw).write(to: file.url)
        XCTAssertThrowsError(try file.read())
    }
    func testIdentityRoutesRejectArbitraryInputAndNeverDisplayChangedContent() async throws {
        let id = try SystemReadingBookID(sha: String(repeating: "a", count: 64))
        XCTAssertEqual(try SystemReadingRequest(url: SystemReadingRequest.openBook(id).url), .openBook(id))
        for value in ["book:pending:local", "book:" + String(repeating: "A", count: 64), "file:///private/book.txt"] {
            XCTAssertThrowsError(try SystemReadingBookID(rawValue: value))
        }
        for url in ["moonread://reading/book/../x", "moonread://reading/continue?offset=4", "moonread://reading/continue#x", "moonread://user@reading/continue"] {
            XCTAssertThrowsError(try SystemReadingRequest(url: URL(string: url)!))
        }
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let entry = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first)
        var pending = try await service.libraryEntry(entry.id)
        pending.contentSha256 = "pending:synthetic"
        pending.readingIdentity = .pending(bookId: "synthetic")
        XCTAssertNil(try pending.systemReadingIdentity, "An unfinished in-App resume never invents a public ID")
        let route = ReaderRoute.source(SourceFile(id: entry.id, shelfID: entry.shelfId, relativePath: entry.relativePath))
        let session = ReaderSession(service: service)
        await session.open(route, request: OpeningRequest(target: route, expectedContentSHA: id.sha))
        try await waitForLibraryState { session.error != nil }
        XCTAssertNil(session.window)
        XCTAssertEqual(session.error, SystemReadingRouteError.contentChanged.errorDescription)
        await session.leave().value
    }
    func testSystemBookQueryUsesOnlyMetadataAndExplicitSelectionSurvivesAutomaticExclusion() async throws {
        let first = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "a", count: 64), title: "合成甲", author: "合成作者", tags: ["远航"], availability: .available, sourceCount: 1, naturalOrdinal: 1, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: false)
        let second = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "b", count: 64), title: "合成乙", author: nil, tags: [], availability: .reconnectRequired, sourceCount: 1, naturalOrdinal: 0, progress: nil, chapterLabel: nil, recentRank: 0, allowsAutomaticExposure: true)
        let snapshot = SystemReadingSnapshot(storeScope: "test", books: [first, second], recentIDs: [second.id], exposurePolicy: .init(systemSearchEnabled: false, excludedShelfIDs: []))
        let query = SystemBookQuery(readSnapshot: { snapshot })
        let match = try await query.entities(matching: "远航")
        XCTAssertEqual(match.map(\.id), [first.id])
        let explicit = try await query.entities(for: [first.id, "not-present"])
        XCTAssertEqual(explicit.map(\.id), [first.id])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [second.id])
        let missing = SystemBookQuery(readSnapshot: { throw CocoaError(.fileReadNoPermission) })
        do { _ = try await missing.suggestedEntities(); XCTFail("Unreadable snapshots must not manufacture a book") } catch { }
    }
    func testIntentHandoffIsOneShotAndStatisticsBoundsUseLocalCalendar() async throws {
        try SystemReadingIntentDelivery.submit(.resume)
        try SystemReadingIntentDelivery.submit(.book("book:" + String(repeating: "c", count: 64)))
        XCTAssertEqual(SystemReadingIntentDelivery.take(), .book("book:" + String(repeating: "c", count: 64)))
        XCTAssertNil(SystemReadingIntentDelivery.take())
        _ = try await OpenMyBookshelfIntent().perform()
        XCTAssertEqual(SystemReadingIntentDelivery.take(), .library)
        var search = SearchSystemBooksIntent()
        search.query = "巫师"
        _ = try await search.perform()
        XCTAssertEqual(SystemReadingIntentDelivery.take(), .search("巫师"))
        search.query = nil
        _ = try await search.perform()
        XCTAssertEqual(SystemReadingIntentDelivery.take(), .search(""))
        for request in [SystemReadingRequest.showLibrary, .searchBooks(""), .searchBooks("巫师 & wizard")] {
            XCTAssertEqual(try SystemReadingRequest(url: request.url), request)
        }
        for invalid in ["moonread://reading/search?offset=3", "moonread://reading/search?query=x&query=y"] {
            XCTAssertThrowsError(try SystemReadingRequest(url: URL(string: invalid)!))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 10))!
        let today = SystemStatisticsPeriod.today.bounds(now: date, calendar: calendar)
        let week = SystemStatisticsPeriod.week.bounds(now: date, calendar: calendar)
        XCTAssertEqual(today.lowerBound, today.upperBound)
        XCTAssertEqual(week.upperBound, today.upperBound)
        XCTAssertEqual(week.upperBound - week.lowerBound, 6)
    }

    func testSpotlightMetadataChangesAndShelfExclusionUseOnePolicy() async throws {
        let (root, service, _, _, _, first, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file); await service.waitForSystemReadingCatalog()
        let probe = SystemSearchProbe()
        let adapter = SystemSpotlightAdapter(index: { try await probe.index($0) }, delete: { await probe.delete($0) }, deleteAll: { await probe.deleteAll() })
        let snapshot = try file.read()
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        let before = await probe.result()
        XCTAssertEqual(before.0, 1, "An unchanged display summary is not reindexed")
        XCTAssertEqual(before.1.count, 2)
        await service.requestSystemSpotlightReindex()
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        let stale = await probe.result()
        XCTAssertEqual(stale.0, 1, "A superseded generation cannot answer a new rebuild request")
        try await service.reconcileSystemSpotlight(file.read(), using: adapter)
        let rebuilt = await probe.result()
        XCTAssertEqual(rebuilt.0, 2)
        try await service.setSystemSearch(enabled: true, excludedShelfIDs: ["builtin"])
        let excluded = try file.read()
        XCTAssertEqual(excluded.books.count, 2, "Explicit selection/widget catalogue remains available")
        XCTAssertTrue(excluded.books.allSatisfy { !$0.allowsAutomaticExposure })
        try await service.reconcileSystemSpotlight(excluded, using: adapter)
        let after = await probe.result()
        XCTAssertEqual(Set(after.2), Set(snapshot.books.map(\.id)))
        let sha = try await service.snapshot(first.id).book.contentSha256
        let id = try SystemReadingBookID(sha: sha)
        _ = try await service.resolveSystemReadingBook(id)
        do { _ = try await service.resolveSystemReadingBook(id, automatic: true); XCTFail("Stale Spotlight links must respect current exclusions") }
        catch SystemReadingRouteError.searchDisabled { }
    }
    func testSystemSearchPartialPinyinAndSpotlightPresentation() async throws {
        let book = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "a", count: 64), title: "巫师之旅", author: "刘慈欣", tags: ["奇幻"], availability: .available, sourceCount: 1, naturalOrdinal: 0, progress: 42, chapterLabel: "第一章 月下归舟", recentRank: nil, allowsAutomaticExposure: true)
        let traditional = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "b", count: 64), title: "巫師之旅", author: nil, tags: [], availability: .available, sourceCount: 1, naturalOrdinal: 1, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: true)
        let english = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "c", count: 64), title: "The Wizard Journey", author: "Alex River", tags: [], availability: .available, sourceCount: 1, naturalOrdinal: 2, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: true)
        let query = SystemBookQuery(readSnapshot: { .init(storeScope: "test", books: [book, traditional, english]) })
        for text in ["巫师", "之旅", "wushi", "wushizhilv", "WSZL", "liucixin", "lcx"] {
            let matches = try await query.entities(matching: text)
            XCTAssertTrue(matches.contains { $0.id == book.id }, text)
        }
        let traditionalMatches = try await query.entities(matching: "巫師"), englishMatches = try await query.entities(matching: "wizard")
        XCTAssertEqual(traditionalMatches.map(\.id), [traditional.id])
        XCTAssertEqual(englishMatches.map(\.id), [english.id])
        let metadata = SystemSpotlightMetadata(id: book.id, title: book.title, author: book.author, tags: book.tags, chapterLabel: book.chapterLabel, progress: book.progress)
        for text in ["巫师", "wushizhilv", "wszl", "liucixin", "lcx"] { XCTAssertTrue(metadata.keywords.contains(text), text) }
        let englishTerms = LibraryQueryRules.systemMetadataTerms(title: english.title, author: english.author, tags: [])
        XCTAssertTrue(englishTerms.contains("The Wizard")); XCTAssertTrue(englishTerms.contains("Wizard"))
        let thumbnail = try XCTUnwrap(SystemSpotlightMetadata.textThumbnail(title: book.title))
        let attributes = metadata.attributes(thumbnail: thumbnail)
        XCTAssertEqual(attributes.thumbnailData, thumbnail)
        XCTAssertTrue(attributes.contentDescription?.contains("刘慈欣 · 第一章 月下归舟 · ") == true)
        XCTAssertTrue(attributes.contentDescription?.contains("42") == true)
        XCTAssertNil(attributes.textContent); XCTAssertNil(attributes.contentURL)
        let empty = SystemSpotlightMetadata(id: book.id, title: book.title, author: nil, tags: [])
        XCTAssertTrue(empty.contentDescription.isEmpty, "Unknown chapters/progress are never fabricated")
    }

    func testFailedSpotlightSubmissionRemainsRevocableWhenDisabled() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file); await service.waitForSystemReadingCatalog()
        let probe = SystemSearchProbe(fail: true)
        let adapter = SystemSpotlightAdapter(index: { try await probe.index($0) }, delete: { await probe.delete($0) }, deleteAll: { await probe.deleteAll() })
        let snapshot = try file.read()
        do { try await service.reconcileSystemSpotlight(snapshot, using: adapter); XCTFail("Injected failure must surface") } catch { }
        try await service.setSystemSearch(enabled: false, excludedShelfIDs: [])
        let disabled = try file.read()
        XCTAssertFalse(disabled.exposurePolicy.systemSearchEnabled)
        try await service.reconcileSystemSpotlight(disabled, using: adapter)
        let calls = await probe.result()
        XCTAssertEqual(Set(calls.2), Set(snapshot.books.map(\.id)), "Even possibly partially indexed IDs are deleted")
    }

    func testWidgetSelectionKeepsItsDisplayedIdentityAndNeverInventsProgress() throws {
        let sample = SystemReadingWidgetModel.sample
        let value = SystemReadingSnapshot(storeScope: "local", books: [sample], recentIDs: [sample.id])
        let recent = SystemReadingWidgetModel.selection(in: value, selectedID: nil)
        XCTAssertEqual(recent.book?.id, sample.id)
        XCTAssertEqual(recent.book?.progress, 42)
        XCTAssertEqual(recent.targetID, sample.id)
        let unavailableID = "book:" + String(repeating: "b", count: 64)
        let missing = SystemReadingWidgetModel.selection(in: value, selectedID: unavailableID)
        XCTAssertNil(missing.book)
        XCTAssertEqual(missing.targetID, unavailableID, "A stale configured book never falls back to another recent book")
        let unreadable = SystemReadingWidgetModel.selection(in: nil, selectedID: unavailableID)
        XCTAssertNil(unreadable.book?.progress)
        XCTAssertEqual(unreadable.targetID, unavailableID)
        XCTAssertEqual(try SystemReadingRequest(url: SystemReadingLink.book(unavailableID)!), .openBook(try SystemReadingBookID(rawValue: unavailableID)))
        let empty = SystemReadingWidgetModel.selection(in: .init(storeScope: "new-account"), selectedID: nil)
        XCTAssertNil(empty.book); XCTAssertNil(empty.targetID)
    }

    func testInFlightOldCatalogueCannotOverwriteResetScope() async throws {
        let (root, _, core, formal, pending, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let gate = SystemCatalogueGate()
        let service = AppDataService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite,
            userStoreFactory: { name, _ in
                await gate.wait()
                return name == "pending-users.store" ? pending : formal
            })
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file)
        await gate.waitForEntry()
        let oldTask = await service.systemCatalog?.task
        await service.resetSystemReadingCatalog()
        let reset = try file.read()
        await gate.release()
        await oldTask?.value
        XCTAssertEqual(try file.read(), reset)
        XCTAssertTrue(reset.books.isEmpty)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertEqual(try file.read().books.count, 2)
    }

    func testWidgetFieldsRoundTripAndSearchExclusionsPreserveExplicitDisplay() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file); await service.waitForSystemReadingCatalog()
        let initial = try file.read()
        let stats = try XCTUnwrap(initial.statistics)
        XCTAssertEqual(stats.status, "ready"); XCTAssertEqual(stats.days?.count, 7)
        XCTAssertNotNil(initial.appearance)
        var books = initial.books
        books[0].coverThumbnail = .init(fileName: "cover-synthetic-r1-128.png", revision: "r1-synthetic", pixelWidth: 128, pixelHeight: 192)
        let candidate = SystemReadingSnapshot(storeScope: initial.storeScope, books: books, recentIDs: initial.recentIDs,
            appearance: initial.appearance, statistics: initial.statistics)
        try file.publish(candidate)
        try await service.setSystemSearch(enabled: false, excludedShelfIDs: [])
        let roundTrip = try file.read()
        XCTAssertEqual(roundTrip.statistics?.todayDurationMs, stats.todayDurationMs)
        XCTAssertEqual(roundTrip.appearance, initial.appearance)
        // The restricted publication itself must preserve all display fields;
        // subsequent rebuilds may drop an unavailable synthetic image.
        let restricted = candidate.restrictingAutomaticExposure(to: .init(systemSearchEnabled: false, excludedShelfIDs: []))
        let decoded = try JSONDecoder().decode(SystemReadingSnapshot.self, from: SystemReadingSnapshotFile.encode(restricted))
        XCTAssertEqual(decoded.books[0].coverThumbnail, books[0].coverThumbnail)
        XCTAssertEqual(decoded.statistics, candidate.statistics); XCTAssertEqual(decoded.appearance, candidate.appearance)
        XCTAssertFalse(decoded.books[0].allowsAutomaticExposure)
        XCTAssertEqual(SystemReadingWidgetModel.recentBooks(in: candidate, limit: 4).count, candidate.recentIDs.count)
        XCTAssertEqual(try SystemReadingRequest(url: SystemReadingLink.recent), .showRecent)
    }
    func testWidgetAppearanceUsesAppModeAndAppSlotsWithoutReaderTextures() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var preferences = try await service.themes().preferences
        preferences.appMode = .dark
        preferences.readerMode = .light; preferences.readerLight = .palette(id: "white-light")
        let snapshot = try await service.saveThemes(preferences)
        let dark = await service.systemWidgetAppearance()
        XCTAssertEqual(dark?.preferredDark, true)
        XCTAssertEqual(dark?.light, dark?.dark, "App's forced dark mode applies regardless of Widget host scheme")
        let resolved = try resolveThemes(value: snapshot, system: .light, highContrast: false)
        XCTAssertEqual(dark?.light?.paper, resolved.app.colors?.paper)
        XCTAssertNotEqual(dark?.light?.paper, resolved.reader.colors?.paper)
        preferences.appMode = .light
        _ = try await service.saveThemes(preferences)
        let light = await service.systemWidgetAppearance()
        XCTAssertEqual(light?.preferredDark, false); XCTAssertEqual(light?.light, light?.dark)
        XCTAssertNotEqual(light?.light, dark?.dark)
    }
    func testWidgetStatisticsExpireAtCivilMidnightAndRejectChangedCalendarOrUnknownStatus() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")); calendar.firstWeekday = 2
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 10)))
        let end = try XCTUnwrap(calendar.dateInterval(of: .day, for: now)?.end)
        XCTAssertLessThan(end.timeIntervalSince(now), 24 * 3600 - 60 * 10, "DST boundary uses Calendar, not fixed seconds")
        let value = SystemReadingSnapshot.Statistics(status: "ready", generatedAt: now, localDay: 0, validUntil: end,
            timeZoneID: calendar.timeZone.identifier, calendarID: String(describing: calendar.identifier), firstWeekday: 2,
            recordingEnabled: false, todayDurationMs: 0, weekDurationMs: 0, currentStreakDays: 0, days: (0..<7).map { .init(localDay: Int64($0), durationMs: 0) })
        XCTAssertTrue(value.hasValues(at: now, calendar: calendar), "Paused history is still readable")
        XCTAssertFalse(value.hasValues(at: end, calendar: calendar))
        calendar.firstWeekday = 1; XCTAssertFalse(value.hasValues(at: now, calendar: calendar))
        calendar.firstWeekday = 2; calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(value.hasValues(at: now, calendar: calendar))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["status"] = "future-status"
        let unknown = try JSONDecoder().decode(SystemReadingSnapshot.Statistics.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(unknown.hasValues(at: now, calendar: calendar))
    }
    func testWidgetCoverBudgetUsesControlledFilesAndNeverTouchesOriginalAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 192), format: format).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 192))
        }
        let value = try XCTUnwrap(SystemReadingDerivedCover.encode(try XCTUnwrap(image.cgImage), sha: String(repeating: "a", count: 64), pixels: 384))
        XCTAssertLessThanOrEqual(value.data.count, SystemReadingSnapshotFile.maximumCoverBytes)
        try file.publishCover(value)
        XCTAssertEqual(file.coverData(value.reference), value.data)
        let traversal = SystemReadingSnapshot.CoverThumbnail(fileName: "cover-../../original.jpg", revision: "x", pixelWidth: 10, pixelHeight: 10)
        XCTAssertNil(file.coverData(traversal)); XCTAssertNil(file.coverURL(traversal))
        let sibling = root.appendingPathComponent("original.png")
        try value.data.write(to: sibling)
        file.cleanupCovers(current: [], previous: [])
        XCTAssertNil(file.coverData(value.reference))
        XCTAssertEqual(try Data(contentsOf: sibling), value.data, "Only the owned Covers directory is cleaned")
        let unwritable = SystemReadingSnapshotFile(directory: sibling)
        XCTAssertThrowsError(try unwritable.publishCover(value))
    }
    func testWidgetReloadsFollowDisplayChangesInsteadOfRandomEnvelopeGeneration() async throws {
        let initial = SystemReadingWidgetModel.sampleSnapshot
        let same = SystemReadingSnapshot(storeScope: initial.storeScope, generatedAt: initial.generatedAt.addingTimeInterval(20),
            books: initial.books.map { $0.withAutomaticExposure(false) }, recentIDs: initial.recentIDs,
            exposurePolicy: .init(systemSearchEnabled: false, excludedShelfIDs: []), appearance: initial.appearance, statistics: initial.statistics)
        XCTAssertTrue(SystemReadingWidgetModel.reloadKinds(from: initial, to: same).isEmpty)
        let old = try XCTUnwrap(initial.statistics)
        let changed = SystemReadingSnapshot.Statistics(status: old.status, generatedAt: old.generatedAt, localDay: old.localDay, validUntil: old.validUntil,
            timeZoneID: old.timeZoneID, calendarID: old.calendarID, firstWeekday: old.firstWeekday, recordingEnabled: old.recordingEnabled,
            todayDurationMs: 1, weekDurationMs: old.weekDurationMs, currentStreakDays: old.currentStreakDays, days: old.days)
        let candidate = SystemReadingSnapshot(storeScope: initial.storeScope, books: initial.books, recentIDs: initial.recentIDs, appearance: initial.appearance, statistics: changed)
        XCTAssertEqual(SystemReadingWidgetModel.reloadKinds(from: initial, to: candidate), [SystemReadingWidgetModel.statisticsKind])
        XCTAssertEqual(Set(SystemReadingWidgetModel.reloadKinds(from: initial, to: .init(storeScope: "other"))),
            Set([SystemReadingWidgetModel.continueKind, SystemReadingWidgetModel.recentKind, SystemReadingWidgetModel.statisticsKind]))
        // Actual shared views, synthetic data only; attachments are for visual review,
        // not assertions about system geometry or WidgetKit scheduling.
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let appearance = await service.systemWidgetAppearance()
        for scheme in [ColorScheme.light, .dark] {
            let colors = SystemWidgetColors(tokens: scheme == .dark ? appearance?.dark : appearance?.light)
            let board = VStack(spacing: 20) {
                SystemReadingCard(book: initial.books.first, appearance: appearance).frame(width: 144, height: 144).padding(16).background(colors.paper, in: .rect(cornerRadius: 24)).frame(maxWidth: .infinity, alignment: .leading)
                SystemReadingCard(book: initial.books.first, wide: true, appearance: appearance).frame(width: 320, height: 144).padding(16).background(colors.paper, in: .rect(cornerRadius: 24))
                SystemRecentReadingCard(books: Array(initial.books.prefix(2)), colors: colors).frame(width: 320, height: 144).padding(16).background(colors.paper, in: .rect(cornerRadius: 24))
                SystemRecentReadingCard(books: initial.books, colors: colors, large: true).frame(width: 320, height: 338).padding(16).background(colors.paper, in: .rect(cornerRadius: 24))
                SystemStatisticsCard(statistics: initial.statistics, colors: colors).frame(width: 320, height: 144).padding(16).background(colors.paper, in: .rect(cornerRadius: 24))
            }.padding(20).background(colors.canvas).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: board); renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "widget-v7-" + (scheme == .dark ? "dark" : "light"); attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testReaderHandoffRemovesOnlyItsOldNavigationDestination() {
        let suite = "SystemRoute-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AppDataService(sourceDefaultsSuite: suite)
        let model = LibraryModel(service: service, fullIndex: FullIndexController(defaults: defaults, service: service, registerTasks: false), defaults: defaults, cloudDiscoveryRequired: false)
        let old = OpeningRequest(target: .book("old")), replacement = OpeningRequest(target: .book("replacement"))
        let folder = LibraryRoute.folder(LibraryLocation(shelfID: "builtin"))
        model.libraryPath = [folder, .reader(old), .settings]
        model.statisticsPath = [.reader(replacement)]
        model.removeReaderDestination(old.id)
        XCTAssertEqual(model.libraryPath, [folder])
        XCTAssertEqual(model.statisticsPath, [.reader(replacement)])
        model.removeReaderDestination(old.id)
        XCTAssertEqual(model.statisticsPath, [.reader(replacement)], "Late cleanup cannot pop a newer reader")
    }

}


private actor SystemSearchProbe {
    private var indexes = 0
    private var items: [SystemSpotlightMetadata] = []
    private var deleted: [String] = []
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func index(_ items: [SystemSpotlightMetadata]) throws {
        indexes += 1; self.items += items
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
    func delete(_ ids: [String]) { deleted += ids }
    func deleteAll() { }
    func result() -> (Int, [SystemSpotlightMetadata], [String]) { (indexes, items, deleted) }
}


private actor SystemCatalogueGate {
    private var open = false
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let watching = observers; observers.removeAll(); for item in watching { item.resume() }
        if !open { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

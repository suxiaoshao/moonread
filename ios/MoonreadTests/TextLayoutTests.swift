import XCTest
import UIKit
import SwiftUI
import SwiftData
import Observation
import SQLite3
@testable import Moonread

@MainActor private final class DiscoverySourceStub: CloudDiscoverySource {
    var fails = false
    var receive: ((CloudDocumentSnapshot) -> Void)?
    var failed: ((UUID) -> Void)?
    var generation: UUID?
    func start(generation: UUID, receive: @escaping (CloudDocumentSnapshot) -> Void, failed: @escaping (UUID) -> Void) {
        self.generation = generation; self.receive = receive; self.failed = failed
        if fails { failed(generation) }
    }
    func stop() { receive = nil; failed = nil; generation = nil }
}

@MainActor final class ReaderBlankLineTests: XCTestCase {
    #if READER_OPEN_DIAGNOSTICS
    #endif


    func testSelectionRangeReaderUnifiesCrossPageCopySearchAIAndCancelsOnLeave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = "甲🌙段。\n \t　\n乙段。\n", expected = "甲🌙段。\n乙段。\n"
        let file = root.appendingPathComponent("选取.txt"); try Data(raw.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "选取")
        let service = ReaderService(core: core)
        let session = ReaderSession(service: service)
        await session.open(.book(book.id)); await awaitState { session.window != nil }
        var clipboard = [String]()
        let copied = expectation(description: "complete projected selection delivered")
        session.readSelection(start: 0, end: book.byteCount) { range in
            XCTAssertEqual(range.startUtf8, 0); XCTAssertEqual(range.endUtf8, book.byteCount)
            clipboard.append(range.text); copied.fulfill()
        }
        XCTAssertTrue(clipboard.isEmpty)
        await fulfillment(of: [copied], timeout: 3)
        XCTAssertEqual(clipboard, [expected])
        session.readSelection(start: 0, end: book.byteCount) { clipboard.append($0.text) }
        await session.leave().value
        XCTAssertEqual(clipboard, [expected], "Leaving invalidates the pending selection owner")
    }

    func testSingleLineSelectionSearchUsesDisplayedTextAndFindsOriginalOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = "前段。\n\n \t　\n唯一搜索词🌙。\n"
        let file = root.appendingPathComponent("搜索合成.txt")
        try Data(raw.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "搜索合成")
        let query = try core.querySnapshot(json: "{}")
        let projection = ReadingText(ReadingWindow(frame: try query.readingFrame(bookId: book.id, offsetUtf8: 0)))
        let selection = (projection.text as NSString).range(of: "唯一搜索词🌙")
        let envelope = try XCTUnwrap(projection.coordinates.sourceRange(selection))
        let captured = try await ReaderService(core: core).displayTextRange(book.id, start: UInt64(envelope.lowerBound) + projection.sourceStart, end: UInt64(envelope.upperBound) + projection.sourceStart).text
        XCTAssertEqual(captured, "唯一搜索词🌙")
        let job = try query.startSearch(bookId: book.id, query: captured, regularExpression: false, caseSensitive: true, range: nil)
        let batch = try job.nextBatch()
        XCTAssertTrue(batch.done)
        XCTAssertEqual(batch.hits.count, 1)
        XCTAssertEqual(batch.hits.first?.startUtf8, UInt64(envelope.lowerBound) + projection.sourceStart)
        XCTAssertEqual(batch.hits.first?.endUtf8, UInt64(envelope.upperBound) + projection.sourceStart)
        XCTAssertThrowsError(try query.startSearch(bookId: book.id, query: "前段。\n唯一搜索词🌙", regularExpression: false, caseSensitive: true, range: nil))
    }
    private var storages: [NSTextStorage] = []
    private func window(_ text: String) throws -> ReadingWindow {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("合成空行.txt")
        try Data(text.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "合成空行")
        let frame = try core.querySnapshot(json: "{}").readingFrame(bookId: book.id, offsetUtf8: 0)
        return ReadingWindow(frame: frame)
    }

    private func layout(_ source: NSAttributedString, height: CGFloat = 100000) -> (ReadingLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: source), manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 350, height: height)); container.lineFragmentPadding = 0
        storages.append(storage); storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        return (manager, container)
    }
    private func visibleRects(_ manager: NSLayoutManager, _ container: NSTextContainer) -> [CGRect] {
        var result: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in if rect.height > 0 { result.append(rect) } }
        return result
    }
    func testBlankPageBoundariesCoverageNativeLimitsAndCacheVersion() throws {
        let w = try window("\n\n" + String(repeating: "甲乙丙丁合成正文。\n\n\n", count: 70) + "\n\n")
        let settings = defaultReaderSettings(), size = CGSize(width: 390, height: 180)
        let source = ReadingTypography.text(w, settings: settings, ink: .label)
        let pages = TextPage.paginate(w, size: size, attributes: ReadingTypography.attributes(settings, ink: .label), source: source)
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(pages.map { $0.text.string }.joined(), ReadingText(w).text)
        for (page, next) in zip(pages, pages.dropFirst()) { XCTAssertEqual(page.end, next.start) }
        for page in pages {
            XCTAssertGreaterThan(page.lineCount, 0)
            XCTAssertEqual(page.readingText.sourceStart,page.start)
            XCTAssertEqual(page.readingText.sourceEnd,page.end)
            let view = page.makeTextView(frame: CGRect(origin: .zero, size: size)); view.layoutIfNeeded(); view.layoutManager.ensureLayout(for: view.textContainer)
            let rendered = view.layoutManager.characterRange(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer), actualGlyphRange: nil)
            XCTAssertEqual(rendered.length, page.text.length, "Native limit must include folded fragments, excluding lookahead")
            XCTAssertEqual(visibleRects(view.layoutManager, view.textContainer).count, page.lineCount)
            XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).height, size.height - page.insets.top - page.insets.bottom + 0.1)
        }
        var stale = pages; for index in stale.indices { stale[index].layoutVersion -= 1 }
        let refreshed = TextPage.paginate(w, size: size, attributes: ReadingTypography.attributes(settings, ink: .label), source: source, preserving: stale)
        XCTAssertTrue(refreshed.allSatisfy { $0.layoutVersion == ReadingTypography.layoutVersion })
        XCTAssertEqual(refreshed.map { $0.text.string }.joined(), ReadingText(w).text)
    }
    func testProjectionAffinitySelectionCopyAndPreviewKeepOneMapping() throws {
        let raw = "\n\n甲🌙e\u{301}👩‍👩‍👧‍👦。\n \t　\n\n乙。\n\n"
        let window = try window(raw), projection = ReadingText(window)
        XCTAssertEqual(projection.text, "甲🌙e\u{301}👩‍👩‍👧‍👦。\n乙。\n")
        let seam = (projection.text as NSString).range(of:"乙").location
        let map = projection.coordinates
        let before = try XCTUnwrap(map.sourcePoint(seam,affinity:.upstream))
        let after = try XCTUnwrap(map.sourcePoint(seam,affinity:.downstream))
        XCTAssertLessThan(before,after)
        XCTAssertNil(map.displayRange(before..<after), "Pure blank annotations have no visible highlight")
        XCTAssertEqual(map.displayPoint(before),seam)
        let first = try XCTUnwrap(map.sourceRange(NSRange(location:0,length:seam)))
        XCTAssertEqual(first.upperBound,before)
        let second = try XCTUnwrap(map.sourceRange(NSRange(location:seam,length:1)))
        XCTAssertEqual(second.lowerBound,after)
        let all = try XCTUnwrap(map.sourceRange(NSRange(location:0,length:projection.text.utf16.count)))
        XCTAssertTrue(all.contains(before)); XCTAssertTrue(all.contains(after))
        XCTAssertNil(map.displayPoint(-1)); XCTAssertNil(map.displayPoint(map.byteCount+1))
        for segment in map.segments where segment.retained {
            for offset in 0..<segment.display.length {
                let display = segment.display.location+offset
                let original = try XCTUnwrap(map.sourcePoint(display))
                let roundtrip = try XCTUnwrap(map.displayPoint(original))
                XCTAssertEqual(map.sourcePoint(roundtrip),original)
            }
        }
        let left = projection.slice(NSRange(location:0,length:seam)), right = projection.slice(NSRange(location:seam,length:projection.text.utf16.count-seam))
        XCTAssertEqual(left.sourceEnd,right.sourceStart)
        XCTAssertEqual(left.text+right.text,projection.text)
        let cover = projection.prefixed("\u{fffc}\n")
        XCTAssertNil(cover.coordinates.sourcePoint(0)); XCTAssertNil(cover.coordinates.sourcePoint(1))
        XCTAssertEqual(cover.coordinates.sourcePoint(2),map.sourcePoint(0))
        let preview = ReadingPreviewTextView(); preview.frame = CGRect(x:0,y:0,width:390,height:500)
        preview.configure(source:.init(window:window,anchor:0,title:"合成"),settings:defaultReaderSettings(),surface:.initial,typeSize:.large)
        preview.layoutIfNeeded(); XCTAssertEqual(preview.text,projection.text)
        XCTAssertGreaterThanOrEqual(preview.capturePosition().anchor,projection.firstVisibleOffset!)
        let page = try XCTUnwrap(TextPage.paginate(window,size:CGSize(width:390,height:200),attributes:ReadingTypography.attributes(defaultReaderSettings(),ink:.label),source:ReadingTypography.text(window,settings:defaultReaderSettings(),ink:.label)).first)
        let view = page.makeTextView(frame:CGRect(x:0,y:0,width:390,height:200))
        var copied: (UInt64, UInt64)?
        (view as? ReadingTextView)?.copySelection = { copied = ($0, $1) }
        view.selectAll(nil); view.copy(nil)
        let selected = try XCTUnwrap(page.readingText.coordinates.sourceRange(page.readingText.selectableRange))
        XCTAssertEqual(copied?.0, page.readingText.sourceStart + UInt64(selected.lowerBound))
        XCTAssertEqual(copied?.1, page.readingText.sourceStart + UInt64(selected.upperBound))
        XCTAssertEqual(view.accessibilityLabel,page.readingText.text)
    }
    func testOrdinaryEndHitTestingKeepsTheNativeInsertionBoundary() throws {
        let w = try window("普通正文结束🌙")
        let settings = defaultReaderSettings(), size = CGSize(width: 390, height: 500)
        let source = ReadingTypography.text(w, settings: settings, ink: .label)
        let page = try XCTUnwrap(TextPage.paginate(w, size: size, attributes: ReadingTypography.attributes(settings, ink: .label), source: source).first)
        let view = page.makeTextView(frame: CGRect(origin: .zero, size: size)); view.layoutIfNeeded()
        let end = try XCTUnwrap(view.closestPosition(to: CGPoint(x: size.width - 1, y: size.height - 1)))
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: end), source.length)
    }
    func testAllBlankProjectionHasNoSyntheticVisiblePage() {
        let raw = "\n \t　\n\n", end = UInt64(raw.utf8.count)
        let window = ReadingWindow(chunks:[.init(index:0,startUtf8:0,endUtf8:end,text:raw)],paragraphs:[.init(startUtf8:0,endUtf8:end,kind:.blank,continuation:false,indented:false)],isEndOfBook:true)
        let projection = ReadingText(window)
        XCTAssertTrue(projection.text.isEmpty); XCTAssertNil(projection.firstVisibleOffset)
        XCTAssertNil(projection.coordinates.displayPoint(0))
        XCTAssertTrue(TextPage.paginate(window,size:CGSize(width:390,height:180),attributes:[:]).isEmpty)
    }

    func testLongBlankFrameProjectionRetainsBothSidesWithinFinitePayload() throws {
        let raw = "甲段。\n"+String(repeating:" \t　\n",count:30000)+"乙段🌙。\n"
        let w = try window(raw), projection = ReadingText(w)
        XCTAssertEqual(projection.text,"甲段。\n乙段🌙。\n")
        XCTAssertGreaterThan(w.end-w.start,4*12*1024)
        XCTAssertLessThan(w.chunks.reduce(0) { $0+$1.text.utf8.count },4*12*1024)
        XCTAssertEqual(w.omitted.count,1)
        let pages = TextPage.paginate(w,size:CGSize(width:390,height:180),attributes:ReadingTypography.attributes(defaultReaderSettings(),ink:.label),source:ReadingTypography.text(w,settings:defaultReaderSettings(),ink:.label))
        XCTAssertEqual(pages.map { $0.readingText.text }.joined(),projection.text)
        XCTAssertEqual(pages.first?.start,0); XCTAssertEqual(pages.last?.end,UInt64(raw.utf8.count))
    }


    func testBusyWindowAdmissionDoesNotConsumeViewportRequest() {
        var admissions = ReadingFrontierAdmissions(), accepted = false, attempts = 0
        let keep = SourceSpan(startUtf8: 3, endUtf8: 30)
        func request() { admissions.request(.forward, cursor: 40, keeping: keep) { attempts += 1; return accepted } }
        request(); XCTAssertEqual(attempts, 1)
        accepted = true; request(); request(); XCTAssertEqual(attempts, 2)
        admissions.reset(); request(); XCTAssertEqual(attempts, 3)
    }

    func testFiniteFrameAndProjectionMetricsForOrdinaryAndLongBlankText() throws {
        let w = try window("甲🌙。\n \t　\n乙。\n")
        let projection = ReadingText(w)
        XCTAssertEqual(projection.text, "甲🌙。\n乙。\n")
        XCTAssertEqual(projection.sourceStart, w.start); XCTAssertEqual(projection.sourceEnd, w.end)
        let point = try XCTUnwrap(projection.coordinates.displayPoint(0))
        XCTAssertEqual(point, 0)
    }

    func testStrictExtensionEndAndUnanchoredReadyKeepReadableWindow() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("边界合成.txt")
        try Data(("甲段。\n"+String(repeating:"合成正文。\n",count:12000)).utf8).write(to:file)
        let core=try ReaderCore(dataDirectory:root.appendingPathComponent("db").path)
        let imported=try core.importBook(filePath:file.path,title:"合成")
        let service=ReaderService(core:core)
        let session=ReaderSession(service:service,activity:ReadingActivityRecorder { StatisticsPreferences(enabled:false,generation:0) })
        await session.open(.book(imported.id))
        await awaitState { session.window != nil }
        let previous=try XCTUnwrap(session.window), anchor=session.anchor
        let held = SourceSpan(startUtf8: previous.projectionAnchor ?? anchor, endUtf8: (previous.projectionAnchor ?? anchor) + 1)
        let deferred = try await service.extensionFrame(imported.id, cursor: imported.byteCount - 1, direction: .backward, retaining: held)
        XCTAssertEqual(deferred.status, .deferred)
        session.acceptExtension(deferred, direction: .backward)
        XCTAssertEqual(session.window, previous)
        let ready=try await service.extensionFrame(imported.id,cursor:imported.byteCount-1,direction:.backward)
        XCTAssertEqual(ready.status,.ready)
        session.acceptExtension(ready,direction:.forward)
        XCTAssertEqual(session.window,previous,"Prefetch cannot silently relocate an anchor outside its finite payload")
        let end=try await service.extensionFrame(imported.id,cursor:imported.byteCount,direction:.forward)
        XCTAssertEqual(end.status,.end)
        session.acceptExtension(end,direction:.forward)
        XCTAssertEqual(session.window?.chunks,previous.chunks)
        XCTAssertEqual(session.window?.paragraphs,previous.paragraphs)
        XCTAssertEqual(session.anchor,anchor); XCTAssertNil(session.window?.nextCursor)
        var waiting = end; waiting.status = .awaiting; waiting.snapshot.phase = .importing; waiting.isEndOfBook = false
        session.acceptExtension(waiting,direction:.forward)
        XCTAssertEqual(session.window?.chunks,previous.chunks)
        XCTAssertEqual(session.window?.paragraphs,previous.paragraphs)
        XCTAssertEqual(session.anchor,anchor); XCTAssertTrue(session.window?.isPreparedTail == true)
        XCTAssertFalse(session.window?.isEndOfBook == true)
        // The same distant frontier becomes admissible after an actual reading
        // move; prefetch itself must not perform that move to escape Deferred.
        let distant = imported.byteCount - UInt64("合成正文。\n".utf8.count)
        session.moved(to: distant, settled: false)
        let moved = try await service.extensionFrame(imported.id, cursor: imported.byteCount - 1, direction: .backward,
                                                     retaining: SourceSpan(startUtf8: distant, endUtf8: distant + 1))
        XCTAssertEqual(moved.status, .ready)
        session.acceptExtension(moved, direction: .backward)
        XCTAssertTrue(session.window?.chunks.contains { $0.startUtf8 <= distant && $0.endUtf8 > distant } == true)
        XCTAssertEqual(session.anchor, distant)
        await session.leave().value
    }



}

@MainActor private final class ReadingScreenshotFrames: NSObject {
    private let ready: XCTestExpectation
    private var count = 0
    private var link: CADisplayLink?
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func start() { link = CADisplayLink(target: self, selector: #selector(frame)); link?.add(to: .main, forMode: .common) }
    @objc private func frame() { count += 1; if count == 2 { link?.invalidate(); link = nil; ready.fulfill() } }
}

private actor SourceReadinessGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor EncodingRestartProbe {
    let gate: SourceReadinessGate
    let holdAfterCreation: Bool
    private(set) var calls = 0
    private(set) var createdIDs: [String] = []
    init(gate: SourceReadinessGate, holdAfterCreation: Bool = false) {
        self.gate = gate; self.holdAfterCreation = holdAfterCreation
    }
    func run(service: ReaderService, id: String, encoding: String?) async throws -> ReadingLease {
        calls += 1
        if !holdAfterCreation { await gate.wait() }
        let lease = try await service.restartImport(id, encoding: encoding)
        createdIDs.append(lease.id)
        if holdAfterCreation { await gate.wait() }
        return lease
    }
}

private actor LibraryRefreshProbe {
    private(set) var passes = 0
    let gate: SourceReadinessGate
    init(gate: SourceReadinessGate) { self.gate = gate }
    func refresh() async {
        passes += 1
        if passes == 1 { await gate.wait() }
    }
}

private actor LibraryInitializationProbe {
    private(set) var attempts = 0
    let gate: SourceReadinessGate
    init(gate: SourceReadinessGate) { self.gate = gate }
    func prepare(_ service: ReaderService) async throws {
        attempts += 1
        if attempts == 1 { throw CocoaError(.fileWriteOutOfSpace) }
        await gate.wait()
        try await service.prepareLibrary()
    }
}

final class TextLayoutTests: XCTestCase {
    @MainActor func testActivityStartCancellationAndStopReleaseLateLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let entered = expectation(description: "preferences suspended")
        let gate = SourceReadinessGate(entered: entered)
        let recorder = ReadingActivityRecorder { await gate.wait(); return StatisticsPreferences(enabled: true, generation: 0) }
        let token = UUID(); recorder.prepareStart(token)
        var lease: ReadingLease? = ReadingLease(id: "cancelled", service: service)
        weak var retained = lease
        let task = Task { [lease = lease!] in await recorder.start(lease: lease, viewport: ReadingViewportAccess(), attempt: token) }
        lease = nil
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); recorder.stop()
        await gate.release(); await task.value
        XCTAssertNil(recorder.recordingBookID); XCTAssertFalse(recorder.hasSamplingTimer)
        for _ in 0..<20 { if retained == nil { break }; await Task.yield() }
        XCTAssertNil(retained)
    }

    @MainActor func testActivityOldAttemptCannotOverwriteNewClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let entered = expectation(description: "old preferences")
        let gate = SourceReadinessGate(entered: entered)
        var calls = 0
        let recorder = ReadingActivityRecorder {
            calls += 1
            if calls == 1 { await gate.wait() }
            return StatisticsPreferences(enabled: true, generation: 0)
        }
        let old = UUID(); recorder.prepareStart(old)
        let task = Task { await recorder.start(lease: ReadingLease(id: "old", service: service), viewport: ReadingViewportAccess(), attempt: old) }
        await fulfillment(of: [entered], timeout: 2)
        let fresh = UUID(); recorder.prepareStart(fresh)
        await recorder.start(lease: ReadingLease(id: "new", service: service), viewport: ReadingViewportAccess(), attempt: fresh)
        XCTAssertEqual(recorder.recordingBookID, "new")
        recorder.update(readable: false, preview: false) // Background state remains authoritative during a late start.
        await gate.release(); await task.value
        XCTAssertEqual(recorder.recordingBookID, "new"); XCTAssertTrue(recorder.hasSamplingTimer)
        recorder.stop()
    }

    @MainActor func testReaderMonitorDoesNotWaitForStatisticsAndLeavingStopsLateStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let source = root.appendingPathComponent("synthetic.txt")
        try "第一章 春风\n中文正文。\n".write(to: source, atomically: true, encoding: .utf8)
        let book = try core.importBook(filePath: source.path, title: "合成")
        let service = ReaderService(core: core)
        let entered = expectation(description: "statistics not ready")
        let gate = SourceReadinessGate(entered: entered)
        let recorder = ReadingActivityRecorder { await gate.wait(); return StatisticsPreferences(enabled: true, generation: 0) }
        let session = ReaderSession(service: service, activity: recorder)
        await session.open(.book(book.id))
        await fulfillment(of: [entered], timeout: 2)
        await awaitState { session.window != nil }
        XCTAssertNotNil(session.window); XCTAssertNil(recorder.recordingBookID)
        XCTAssertTrue(session.showingCover, "Statistics startup must not bypass the first-reading cover")
        await session.leave().value
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(recorder.recordingBookID); XCTAssertFalse(recorder.hasSamplingTimer)
    }

    @MainActor func testStatisticsWriterKeepsLeaseUntilPendingWriteFinishesAfterRecorderStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let entered = expectation(description: "pending writer")
        let gate = SourceReadinessGate(entered: entered)
        let writer = StatisticsWriter { _, _ in await gate.wait() }
        var lease: ReadingLease? = ReadingLease(id: "pending-write", service: service)
        weak var retained = lease
        let clock = ReadingClock(bookId: "pending-write")
        var moment = ReadingMoment(monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, preview: false, startUtf8: 0, endUtf8: 9)
        _ = clock.update(moment: moment)
        moment.monotonicMs = 1000; moment.unixMs = 1000; moment.readable = false
        let slices = clock.update(moment: moment)
        XCTAssertFalse(slices.isEmpty)
        writer.enqueue(slices, generation: 0, lease: lease!)
        let recorder = ReadingActivityRecorder()
        recorder.stop(); lease = nil
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(retained, "Cancelling startup must not invalidate a writer-owned lease")
        await gate.release(); await writer.drain()
        for _ in 0..<20 { if retained == nil { break }; await Task.yield() }
        XCTAssertNil(retained)
    }

    @MainActor func testActivityLateStartRespectsBackgroundAndNeverBackdatesVisibleReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let viewport = ReadingViewportAccess(range: { (0, 30) })
        let time = ManualTestClock()
        var written: [ReadingSlice] = []
        let writer = StatisticsWriter { slices, _ in written += slices }
        let entered = expectation(description: "late preferences")
        let gate = SourceReadinessGate(entered: entered)
        let recorder = ReadingActivityRecorder(writer: writer, time: { ReadingActivityTime(uptime: time.now.timeIntervalSince1970 - 1_800_000_000, date: time.now) }) { await gate.wait(); return StatisticsPreferences(enabled: true, generation: 0) }
        let attempt = UUID(); recorder.prepareStart(attempt)
        recorder.update(readable: true, preview: false)
        let task = Task { await recorder.start(lease: ReadingLease(id: "visible", service: service), viewport: viewport, attempt: attempt) }
        await fulfillment(of: [entered], timeout: 2)
        time.advance(30)
        recorder.update(readable: false, preview: false) // Scene went inactive while the startup was suspended.
        await gate.release(); await task.value
        time.advance(30); await recorder.flush()
        XCTAssertTrue(written.isEmpty, "A late start must not undo the latest inactive/readability state")
        let foreground = Int64(time.now.timeIntervalSince1970 * 1000)
        recorder.update(readable: true, preview: false); recorder.interacted()
        time.advance(30)
        recorder.update(readable: false, preview: false); await recorder.flush()
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.allSatisfy { $0.startedMs >= foreground }, "Never count preparation or the startup wait as reading")
        recorder.stop(); await writer.drain()
    }

    @MainActor func testReaderSettingsFailureDoesNotCreateActivityOrLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Moonread.InvalidSettings.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)!.set("invalid", forKey: "Moonread.readerSettings")
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path), sourceDefaultsSuite: suite)
        let recorder = ReadingActivityRecorder { XCTFail("No startup after settings failure"); return StatisticsPreferences(enabled: true, generation: 0) }
        let session = ReaderSession(service: service, activity: recorder)
        await session.open(.book("missing"))
        XCTAssertNotNil(session.error); XCTAssertNil(session.readingID); XCTAssertFalse(recorder.hasSamplingTimer)
        await session.leave().value
    }

    @MainActor private func singleBookFixture() throws -> (URL, ReaderService, ReaderCore, UserDataStore, UserDataStore, ImportText, ImportText, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let schema = UserDataStore.schema
        let formal = UserDataStore(modelContainer: try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        let pending = UserDataStore(modelContainer: try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        let suite = "SingleBook.\(UUID().uuidString)"
        let service = ReaderService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite, userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try "第一章 合成甲\n春风吹过合成的书页。\n第二章 合成\n继续正文。\n".write(to: a, atomically: true, encoding: .utf8)
        try "第一章 合成乙\n仅用于回归的第二本书。\n".write(to: b, atomically: true, encoding: .utf8)
        let first = try core.importBook(filePath: a.path, title: "甲"), second = try core.importBook(filePath: b.path, title: "乙")
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: a.deletingLastPathComponent().bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), location: "local", builtin: true)
        try core.scanLibraryShelf(shelfId: "builtin", items: [.init(relativePath: "a.txt", directory: false, size: first.byteCount, modified: 0, needsDownload: false), .init(relativePath: "b.txt", directory: false, size: second.byteCount, modified: 0, needsDownload: false)])
        for file in try core.sourceFiles(shelfId: "builtin") { try core.linkLibraryFile(fileId: file.id, bookId: file.relativePath == "a.txt" ? first.id : second.id) }
        return (root, service, core, formal, pending, first, second, suite)
    }

    @MainActor func testPreviewCancelContinueBookmarkAndImmediateReopenUseFormalPosition() async throws {
        let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let session = ReaderSession(service: service)
        await session.open(.book(book.id)); await awaitState { session.window != nil }
        let origin = UInt64("第一章 合成甲\n".utf8.count), target = origin + 6
        session.showingCover = false; session.moved(to: origin, settled: true); await session.flush()
        let added = await session.toggleBookmark(); XCTAssertTrue(added)
        session.browse(to: target); await awaitState { !session.navigating }
        XCTAssertEqual(session.browseOrigin, origin)
        let preview = try await service.snapshot(book.id); XCTAssertEqual(preview.book.positionUtf8, origin)
        XCTAssertEqual(session.history.entries.filter { session.history.isSelected($0.id) }.count, 1)
        await session.returnFromBrowse(); XCTAssertEqual(session.anchor, origin); XCTAssertNil(session.browseOrigin)
        session.browse(to: target); await awaitState { !session.navigating }; await session.continueReading()
        XCTAssertNil(session.browseOrigin)
        await session.leave().value
        let reopened = ReaderSession(service: service)
        await reopened.open(.book(book.id)); await awaitState { reopened.window != nil }
        XCTAssertEqual(reopened.anchor, target)
        await reopened.leave().value
    }

    @MainActor func testContextualResultUsesHostRouteAndPreservesSuspendedReaderPath() async throws {
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let entry = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")[1]
        let model = LibraryModel(service: service, prepareSource: { _, _ in })
        model.path = [.folder(.init(shelfID: "builtin"))]
        let origin = model.path
        let pushed = expectation(description: "Context host receives actual source route")
        var route: LibraryRoute?
        model.open(entry, push: { route = $0; pushed.fulfill() })
        await fulfillment(of: [pushed], timeout: 3)
        XCTAssertEqual(model.path, origin)
        guard case let .reader(request) = route else { return XCTFail("Missing source reader route") }
        XCTAssertEqual(request.target, .source(entry.source))
        let previousLayout = model.layout; model.layout = .list
        XCTAssertEqual(model.path, origin); model.layout = previousLayout
    }

    @MainActor func testSingleBookProjectionMatchesBatchAndInvalidatesWithoutMutatingOldSnapshot() async throws {
        let (root, service, _, formal, _, book, other, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await service.savePosition(bookID: book.id, offset: 20)
        try await service.savePosition(bookID: other.id, offset: 0)
        try await formal.put("metadata/\(book.contentSha256)/author", value: "\"合成作者\"", device: "fixture")
        try await formal.put("metadata/\(other.contentSha256)/author", value: "\"其他作者\"", device: "fixture")
        try await service.correctChapter(book.id, offset: 0, title: "覆盖章名", level: 1)
        let scoped = try await service.bookQuery(book.id), batch = try await service.effectiveQuery()
        XCTAssertEqual(try scoped.readingSnapshot(bookId: book.id), try batch.readingSnapshot(bookId: book.id))
        XCTAssertEqual(try scoped.readingFrame(bookId: book.id, offsetUtf8: 20), try batch.readingFrame(bookId: book.id, offsetUtf8: 20))
        XCTAssertEqual(try scoped.bookDetails(bookId: book.id, contentSha: nil), try batch.bookDetails(bookId: book.id, contentSha: nil))
        let same = try await service.bookQuery(book.id); XCTAssertTrue(scoped === same)
        let old = try scoped.readingSnapshot(bookId: book.id).book.positionUtf8
        try await service.savePosition(bookID: book.id, offset: 44)
        let newer = try await service.bookQuery(book.id)
        XCTAssertFalse(scoped === newer); XCTAssertEqual(try scoped.readingSnapshot(bookId: book.id).book.positionUtf8, old)
        XCTAssertNotEqual(try newer.readingSnapshot(bookId: book.id).book.positionUtf8, old)
        try await service.hideRecent(book.id)
        let hidden = try await service.bookQuery(book.id)
        XCTAssertTrue(try hidden.recentLibraryEntries(limit: 3).isEmpty)
        NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
        let remote = try await service.bookQuery(book.id); XCTAssertFalse(remote === hidden)
        try await service.setStatisticsEnabled(false)
        let generation = try await service.bookQuery(book.id); XCTAssertFalse(generation === remote)
        UserDefaults(suiteName: suite)!.set("fixture-preferred", forKey: "Moonread.preferredFile." + book.contentSha256)
        let preferred = try await service.bookQuery(book.id); XCTAssertFalse(preferred === generation)
        XCTAssertEqual(try preferred.readingSnapshot(bookId: book.id).book.positionUtf8, 44)
        let input = try await formal.projection(generation: 0, enabled: true, includeFacts: false, keys: [book.contentSha256])
        XCTAssertFalse(input.contains(other.contentSha256), "Single-book inputs must not fetch/project another book")
    }

    @MainActor func testPendingAliasPositionIsReadableBeforeStartupRecoveryAndPromotion() async throws {
        let (root, service, core, _, pending, book, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let control = try core.createImport(title: "待准备")
        let id = control.bookId()
        let position = String(decoding: try JSONEncoder().encode(PositionValue(content_key: "pending:" + id, offset: 20)), as: UTF8.self)
        try await pending.put("position/pending:" + id, value: position, device: "fixture")
        try core.reuseImport(control: control, existingId: book.id)
        let update = try await service.openingFrame(id, offset: nil)
        XCTAssertTrue(update.0.hasStarted); XCTAssertEqual(update.0.book.positionUtf8, 20)
        XCTAssertNotNil(update.1)
        let recovered = await service.recoveredImports; XCTAssertFalse(recovered, "Reading never runs startup recovery")
        let before = try await pending.value("position/pending:" + id); XCTAssertNotNil(before, "Reading must not compact or transfer records")
        try await service.promoteUserData(id)
        let after = try await service.snapshot(book.id)
        XCTAssertEqual(after.book.positionUtf8, 20); XCTAssertTrue(after.hasStarted)
    }

    @MainActor func testLibraryLayoutDefaultsToGridAndKeepsAStoredChoice() throws {
        let suite = "LibraryLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LibraryModel(defaults: defaults).layout, .grid)
        LibraryModel(defaults: defaults).layout = .list
        XCTAssertEqual(LibraryModel(defaults: defaults).layout, .list, "A chosen layout survives the new default")
    }

    @MainActor func testBuiltinDiscoveryRequiresAdoptionAndDirectoryReload() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let entered = expectation(description: "snapshot scan entered")
        let gate = SourceReadinessGate(entered: entered)
        let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {},
            cloudDiscoveryRequired: true, adoptCloudDocuments: { _ in await gate.wait() })
        XCTAssertEqual(model.builtinDiscovery, .discovering)
        let loaded = await model.load(); XCTAssertTrue(loaded)
        XCTAssertTrue(model.hasUserImportedBooks, "Local content remains usable during discovery")
        let generation = model.discoveryGeneration
        // An empty metadata result is still a real result, not an empty-library signal.
        model.receiveCloudDiscovery(.init(generation: generation, revision: 1, gathered: true, items: []))
        await fulfillment(of: [entered], timeout: 2)
        model.builtinDirectoryLoaded(generation: generation, snapshotRevision: 1)
        XCTAssertEqual(model.builtinDiscovery, .discovering, "A scan in flight cannot publish empty")
        let changed = expectation(description: "adopted snapshot triggers directory reload")
        withObservationTracking { _ = model.revision } onChange: { changed.fulfill() }
        await gate.release()
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.builtinDiscovery, .discovering, "Adoption alone is insufficient")
        model.builtinDirectoryLoaded(generation: generation, snapshotRevision: 0)
        XCTAssertEqual(model.builtinDiscovery, .discovering, "A stale directory cannot acknowledge the result")
        model.builtinDirectoryLoaded(generation: generation, snapshotRevision: 1)
        XCTAssertEqual(model.builtinDiscovery, .ready)
    }

    @MainActor func testBuiltinDiscoveryFailureAndStaleAccountDoNotPublishEmpty() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {},
            cloudDiscoveryRequired: true, adoptCloudDocuments: { _ in throw CocoaError(.fileReadUnknown) })
        let old = model.discoveryGeneration
        model.failCloudDiscovery(old) // Both query-start failure and the timeout use this boundary.
        XCTAssertEqual(model.builtinDiscovery, .unavailable)
        model.resetCloudDiscovery()
        XCTAssertNotEqual(model.discoveryGeneration, old)
        model.receiveCloudDiscovery(.init(generation: old, revision: 99, gathered: true, items: []))
        model.builtinDirectoryLoaded(generation: old, snapshotRevision: 99)
        model.failCloudDiscovery(old)
        XCTAssertEqual(model.builtinDiscovery, .discovering)
        XCTAssertEqual(model.discoveryRevision, 0)
        model.failCloudDiscovery(model.discoveryGeneration)
        XCTAssertEqual(model.builtinDiscovery, .unavailable)
        CloudDocumentQuery.shared.stop()
    }

    @MainActor func testBuiltinDirectoryFailureFromPreviousAccountDoesNotInvalidateNewDiscovery() throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = LibraryModel(service: service, cloudDiscoveryRequired: true, cloudDiscoverySource: DiscoverySourceStub())
        let directoryGeneration = model.discoveryGeneration
        model.resetCloudDiscovery()
        XCTAssertNotEqual(directoryGeneration, model.discoveryGeneration)
        // A directory read issued for the previous account completes with an error.
        model.failCloudDiscovery(directoryGeneration)
        XCTAssertEqual(model.builtinDiscovery, .discovering)
        model.failCloudDiscovery(model.discoveryGeneration)
        XCTAssertEqual(model.builtinDiscovery, .unavailable, "A current-account failure still reports unavailable")
    }

    @MainActor func testBuiltinDiscoverySourceFailureTimeoutAndLateCallbacks() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let source = DiscoverySourceStub(); source.fails = true
        let entered = expectation(description: "timeout waiting")
        let clock = SourceReadinessGate(entered: entered)
        let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {},
            cloudDiscoveryRequired: true, cloudDiscoverySource: source,
            waitForDiscoveryTimeout: { await clock.wait() }, adoptCloudDocuments: { _ in })
        model.startCloudDiscovery()
        XCTAssertEqual(model.builtinDiscovery, .unavailable, "Query start failure is not an empty library")
        await fulfillment(of: [entered], timeout: 2)
        let previous = model.discoveryGeneration, oldReceive = source.receive
        source.fails = false
        // Reset cancels the old timer. Its callback and metadata cannot affect this account.
        model.resetCloudDiscovery()
        oldReceive?(.init(generation: previous, revision: 10, gathered: true, items: []))
        await clock.release()
        XCTAssertEqual(model.builtinDiscovery, .discovering)
        XCTAssertEqual(model.discoveryRevision, 0)
        let timeoutSource = DiscoverySourceStub()
        let timeoutEntered = expectation(description: "second timeout waiting")
        let timeoutClock = SourceReadinessGate(entered: timeoutEntered)
        let timed = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {},
            cloudDiscoveryRequired: true, cloudDiscoverySource: timeoutSource,
            waitForDiscoveryTimeout: { await timeoutClock.wait() }, adoptCloudDocuments: { _ in })
        timed.startCloudDiscovery()
        await fulfillment(of: [timeoutEntered], timeout: 2)
        let unavailable = expectation(description: "timeout published")
        withObservationTracking { _ = timed.builtinDiscovery } onChange: { unavailable.fulfill() }
        await timeoutClock.release()
        await fulfillment(of: [unavailable], timeout: 2)
        XCTAssertEqual(timed.builtinDiscovery, .unavailable)
    }

    @MainActor func testIntroductionCompletionAndExistingSettingsPersistLocally() async throws {
        let suite = "Introduction-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Existing installs have AI/settings already but no introduction marker.
        let availability = AIAvailability(defaults: defaults)
        XCTAssertTrue(availability.isEnabled)
        let first = Onboarding(defaults: defaults, enabled: false, showIntroduction: true)
        XCTAssertFalse(first.completed); XCTAssertFalse(first.enabled)
        availability.setEnabled(false)
        first.completeIntroduction(destination: .importBook, savingChoices: {})
        if case .importBook = first.takeDestination() { } else { XCTFail("The import request must survive dismissal") }
        XCTAssertNil(first.takeDestination(), "Handle the post-dismiss action exactly once")
        let reloaded = Onboarding(defaults: defaults, enabled: false, showIntroduction: true)
        XCTAssertTrue(reloaded.completed); XCTAssertNil(reloaded.takeDestination())
        XCTAssertFalse(AIAvailability(defaults: defaults).isEnabled)
        availability.setEnabled(true)
        XCTAssertTrue(AIAvailability(defaults: defaults).isEnabled)
        let service = ReaderService(sourceDefaultsSuite: suite)
        let coordinator = CloudSyncCoordinator(service: service, available: false, observeEvents: false)
        await coordinator.setEnabled(true)
        let enabled = await service.cloudSyncRequested(); XCTAssertTrue(enabled)
        await coordinator.setEnabled(false)
        let disabled = await service.cloudSyncRequested(); XCTAssertFalse(disabled)
    }

    @MainActor func testIntroductionPersistsSyncChoiceBeforeCompletionAndImmediateReload() async throws {
        for choice in [true, false] {
            let (root, service, _, suite) = try introductionFixture()
            defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            await service.setCloudSyncRequested(!choice)
            let onboarding = Onboarding(defaults: defaults, enabled: false, showIntroduction: true)
            let cloud = CloudStore(coordinator: CloudSyncCoordinator(service: service, available: false, observeEvents: false))
            let published = expectation(description: "completion is published after the sync intent is persisted")
            withObservationTracking { _ = onboarding.completed } onChange: {
                XCTAssertEqual(UserDefaults(suiteName: suite)?.bool(forKey: "Moonread.userCloudEnabled"), choice)
                published.fulfill()
            }
            var activation: Task<Void, Never>?
            onboarding.completeIntroduction(destination: .library) {
                activation = cloud.saveIntroductionChoice(choice)
            }
            // No background-task wait after completion: model a relaunch now.
            let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertTrue(Onboarding(defaults: reloadedDefaults, enabled: false, showIntroduction: true).completed)
            XCTAssertEqual(reloadedDefaults.bool(forKey: "Moonread.userCloudEnabled"), choice)
            XCTAssertEqual(cloud.status.requested, choice)
            await fulfillment(of: [published], timeout: 1)
            await activation?.value
        }
    }

    @MainActor func testIntroductionCompletesWhileCloudActivationIsSlowOrUnavailable() async throws {
        let (root, service, _, suite) = try introductionFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let entered = expectation(description: "cloud activation is still waiting for its account")
        let gate = SourceReadinessGate(entered: entered)
        let coordinator = CloudSyncCoordinator(service: service, available: true, observeEvents: false, account: {
            await gate.wait()
            throw CocoaError(.fileReadNoPermission)
        })
        let cloud = CloudStore(coordinator: coordinator)
        let onboarding = Onboarding(defaults: defaults, enabled: false, showIntroduction: true)
        var activation: Task<Void, Never>?
        onboarding.completeIntroduction(destination: .library) { activation = cloud.saveIntroductionChoice(true) }
        // These assertions run synchronously, before any account callback can finish.
        XCTAssertTrue(onboarding.completed)
        XCTAssertTrue(defaults.bool(forKey: Onboarding.completionKey))
        XCTAssertTrue(defaults.bool(forKey: "Moonread.userCloudEnabled"))
        XCTAssertTrue(Onboarding(defaults: defaults, enabled: false, showIntroduction: true).completed)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(cloud.busy)
        XCTAssertTrue(onboarding.completed, "A hung CloudKit account request cannot hold the guide open")
        await gate.release()
        await activation?.value
        XCTAssertFalse(cloud.busy)
        XCTAssertFalse(cloud.status.enabled)
        XCTAssertNotNil(cloud.status.message)
        XCTAssertTrue(defaults.bool(forKey: "Moonread.userCloudEnabled"), "Activation failure must not overwrite the choice")
    }

    @MainActor private func introductionFixture(scan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil) throws -> (URL, ReaderService, ReaderCore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let schema = UserDataStore.schema
        let store = UserDataStore(modelContainer: try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        let suite = "Introduction-" + UUID().uuidString
        let service = ReaderService(core: core, libraryDirectory: directory, sourceDefaultsSuite: suite, userStoreFactory: { _, _ in store }, libraryScan: scan)
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), location: "local", builtin: true)
        return (root, service, core, suite)
    }

    @MainActor func testIntroductionStoryRequiresCloudDiscoveryAndEmptyDirectory() async throws {
        let (root, service, core, suite) = try introductionFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = LibraryModel(service: service, prepareLibrary: {}, cloudDiscoveryRequired: true, adoptCloudDocuments: { _ in })
        let loaded = await model.load(); XCTAssertTrue(loaded)
        do { _ = try await model.welcomeStoryForIntroduction(); XCTFail("Discovery must finish first") } catch { }
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path).isEmpty)
        let adopted = expectation(description: "snapshot adopted")
        withObservationTracking { _ = model.revision } onChange: { adopted.fulfill() }
        model.receiveCloudDiscovery(.init(generation: model.discoveryGeneration, revision: 1, gathered: true, items: []))
        await fulfillment(of: [adopted], timeout: 2)
        XCTAssertEqual(model.builtinDiscovery, .discovering)
        do { _ = try await model.welcomeStoryForIntroduction(); XCTFail("Directory acknowledgement must finish first") } catch { }
        model.builtinDirectoryLoaded(generation: model.discoveryGeneration, snapshotRevision: 1)
        let story = try await model.welcomeStoryForIntroduction()
        XCTAssertEqual(story?.name, "月光下的归途.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library/月光下的归途.txt").path))
        let again = try await model.welcomeStoryForIntroduction()
        XCTAssertEqual(again?.id, story?.id)
        XCTAssertEqual(try core.sourceFiles(shelfId: "builtin").count, 1)
        XCTAssertFalse(model.hasUserImportedBooks)
    }

    @MainActor func testIntroductionStoryJoinsSupersedingScanBeforeRecordingSample() async throws {
        let probe = IntroductionScanProbe(first: expectation(description: "sample scan entered"),
                                           second: expectation(description: "successor scan entered"))
        let (root, service, core, suite) = try introductionFixture(scan: { root, _ in try probe.scan(root) })
        defer {
            probe.permits.forEach { $0.signal() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let finished = expectation(description: "sample must wait for successor publication")
        finished.isInverted = true
        let sample = Task {
            let result = try await service.welcomeStory(expectedRoot: nil)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [probe.entered[0]], timeout: 2)
        let successor = Task { try await service.scanLibraryShelf("builtin") }
        await fulfillment(of: [probe.entered[1]], timeout: 2)
        probe.permits[0].signal()
        await fulfillment(of: [finished], timeout: 0.15)
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").isEmpty)
        probe.permits[1].signal()
        let result = try await sample.value
        let entry = try XCTUnwrap(result)
        let published = try await successor.value; XCTAssertTrue(published)
        XCTAssertEqual(entry.relativePath, "月光下的归途.txt")
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: "Moonread.seededExampleFileID"), entry.id)
        let imported = try await service.hasUserImportedBooks(); XCTAssertFalse(imported)
        let repeated = try await service.welcomeStory(expectedRoot: nil)
        XCTAssertEqual(repeated?.id, entry.id)
    }

    @MainActor func testIntroductionStoryNeverOverwritesExistingBooksOrChangedRoot() async throws {
        let (root, service, core, suite) = try introductionFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("library/原创合成.txt")
        try "第一章 测试\n已有合成正文。".write(to: file, atomically: true, encoding: .utf8)
        try await service.scanLibraryShelf("builtin")
        let model = LibraryModel(service: service, prepareLibrary: {}, cloudDiscoveryRequired: false)
        let loaded = await model.load(); XCTAssertTrue(loaded)
        let story = try await model.welcomeStoryForIntroduction(); XCTAssertNil(story)
        XCTAssertEqual(try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["原创合成.txt"])
        do { _ = try await service.welcomeStory(expectedRoot: root); XCTFail("A changed root must be rejected") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "第一章 测试\n已有合成正文。")
    }

    @MainActor func testOnboardingActionEligibilityPersistsWithoutChangingReadingData() throws {
        let suite = "OnboardingTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Onboarding(defaults: defaults, enabled: false)
        XCTAssertFalse(first.imported); XCTAssertFalse(first.revealedControls); XCTAssertFalse(first.selectedText)
        first.didImport(); first.didShowControls(); first.didSelectText()
        let second = Onboarding(defaults: defaults, enabled: false)
        XCTAssertTrue(second.imported); XCTAssertTrue(second.revealedControls); XCTAssertTrue(second.selectedText)
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys.filter { ["Moonread.onboarding.imported", "Moonread.onboarding.controls", "Moonread.onboarding.selection"].contains($0) }), Set(["Moonread.onboarding.imported", "Moonread.onboarding.controls", "Moonread.onboarding.selection"]))
    }

    @MainActor func testHomeSnapshotPublishesAtomicallyAndIgnoresInvisibleReloadChanges() async throws {
        let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await service.savePosition(bookID: book.id, offset: 20)
        let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
        XCTAssertTrue(model.shelves.isEmpty); XCTAssertTrue(model.recents.isEmpty)
        let committed = expectation(description: "atomic home")
        withObservationTracking { _ = model.home } onChange: { committed.fulfill() }
        let loaded = await model.load(); XCTAssertTrue(loaded)
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertTrue(model.homeReady); XCTAssertEqual(model.shelves.count, 1); XCTAssertEqual(model.recents.count, 1)
        let first = model.home, revision = model.revision
        try await model.reload()
        XCTAssertEqual(model.home, first); XCTAssertEqual(model.revision, revision)
        try await service.savePosition(bookID: book.id, offset: 44)
        await model.reloadBook(.book(book.id))
        XCTAssertEqual(model.recents.first?.positionUtf8, 44); XCTAssertEqual(model.revision, revision)
        try FileManager.default.moveItem(at: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("renamed.txt"))
        try await service.scanLibraryShelf("builtin")
        try await model.reload()
        XCTAssertGreaterThan(model.revision, revision, "A same-count nonrecent rename must invalidate folder content")
        let renamedRevision = model.revision
        try await model.reload()
        XCTAssertEqual(model.revision, renamedRevision, "An equal structural index must not invalidate folders again")
    }

    @MainActor func testReplacedFileHasOnlyOneIncrementalHomeRecent() async throws {
        let (root, service, core, _, _, book, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await service.savePosition(bookID: book.id, offset: 20)
        let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
        let loaded = await model.load(); XCTAssertTrue(loaded)
        let old = try XCTUnwrap(model.recents.first)
        try Data("第三章 替换\n只用于增量最近阅读回归的新正文。\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        let replacement = try core.importBook(filePath: root.appendingPathComponent("a.txt").path, title: "替换内容")
        try core.linkLibraryFile(fileId: old.id, bookId: replacement.id)
        try await service.savePosition(bookID: replacement.id, offset: 6)
        await model.reloadBook(.source(old.source))
        XCTAssertEqual(model.recents.filter { $0.id == old.id }.count, 1)
        XCTAssertFalse(model.recents.contains { $0.bookId == book.id })
        XCTAssertEqual(model.recents.first?.bookId, replacement.id)
        XCTAssertEqual(model.recents.first?.positionUtf8, 6)
    }

    @MainActor func testManualEncodingGroupsAreCompleteAndAcceptedByRust() async throws {
        let (root, _, core, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { !$0.directory })
        let groups = ReadingEncodingGroup.allCases
        XCTAssertEqual(groups.count, 6)
        let choices = groups.flatMap(\.encodings)
        XCTAssertEqual(choices.count, 38)
        XCTAssertEqual(Set(choices).count, choices.count)
        for encoding in choices {
            try core.setSourceDecoding(fileId: file.id, decoding: encoding)
            XCTAssertEqual(try core.sourceDecoding(fileId: file.id), encoding)
        }
        for invalid in ["replacement", "iso-2022-cn", "x-user-defined", "UTF-7"] {
            XCTAssertThrowsError(try core.setSourceDecoding(fileId: file.id, decoding: invalid))
        }
        let bundle = try XCTUnwrap(Bundle(path: try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))))
        for (key, expected) in [("简体中文", "Simplified Chinese"), ("繁体中文", "Traditional Chinese"),
                                ("日文", "Japanese"), ("韩文", "Korean"), ("西欧", "Western European"), ("其他编码", "Other Encodings")] {
            XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), expected)
        }
    }

    @MainActor func testSelectedDecodingSurvivesReclaimAndServiceReopen() async throws {
        let (root, service, core, formal, pending, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let path = root.appendingPathComponent("a.txt")
        try Data("第一章\n中文正文测试。\n".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).write(to: path)
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let entry = try await service.libraryEntry(file.id)
        var first: ReadingLease? = try await service.openSourceFile(entry.source)
        try await service.waitForImportsIdle()
        var explicit: ReadingLease? = try await service.restartImport(try XCTUnwrap(first).id, encoding: "utf-16le")
        let taskID = try XCTUnwrap(explicit).id
        try await service.waitForImportsIdle()
        XCTAssertEqual(try core.importStatus(bookId: taskID).phase, .complete)
        let cached = try XCTUnwrap(core.sourceBook(key: SourceContentKey(rawSha256: try CloudDocumentHandoff.bytesHash(path), decoding: "UTF-16LE")))
        try await service.savePosition(bookID: taskID, offset: 9)
        first = nil; explicit = nil
        try await service.waitForReadingIdle()
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "Moonread.importSource.library." + taskID), "The import descriptor must actually be reclaimed")
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "UTF-16LE")
        let reopenedService = ReaderService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite, userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
        let reopened = try await reopenedService.aiPrepare(entry.source)
        let result = try await reopenedService.snapshot(reopened.id)
        XCTAssertEqual(result.book.contentSha256, cached.contentSha256)
        XCTAssertEqual(result.book.positionUtf8, 9)
        XCTAssertEqual(try core.sourceFileLocation(fileId: file.id).bookId, cached.id)
        withExtendedLifetime(reopened) {}
    }

    private func importJobIDs(_ root: URL) throws -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("db/reader.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT book_id FROM import_jobs ORDER BY book_id", -1, &query, nil), SQLITE_OK)
        defer { sqlite3_finalize(query) }
        let statement = try XCTUnwrap(query)
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))))
            status = sqlite3_step(statement)
        }
        XCTAssertEqual(status, SQLITE_DONE)
        return result
    }

    @MainActor func testEncodingRestartAdmitsOnlyOneTaskAndKeepsFilePolicyConsistent() async throws {
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try Data("Chapter 1\nUn caf\u{e9} original sample.\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let source = SourceFile(id: file.id, shelfID: "builtin", relativePath: "a.txt")
        let entered = expectation(description: "restart held before allocation")
        let gate = SourceReadinessGate(entered: entered), probe = EncodingRestartProbe(gate: gate)
        let session = ReaderSession(service: service, activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) }, restartReading: { try await probe.run(service: service, id: $0, encoding: $1) })
        await session.open(.source(source))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil && session.snapshot?.phase == .complete }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let previous = try XCTUnwrap(session.readingID)
        session.restart(encoding: "windows-1252")
        XCTAssertTrue(session.restartingEncoding, "Admission must precede the first actor hop")
        session.restart(encoding: "UTF-8") // ignored, never allocated
        await fulfillment(of: [entered], timeout: 2)
        let calls = await probe.calls; XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.readingID, previous)
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "auto")
        await gate.release()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !session.restartingEncoding && session.readingID != previous && session.snapshot?.phase == .complete }, object: nil)
        await fulfillment(of: [changed], timeout: 5)
        let current = try XCTUnwrap(session.readingID)
        XCTAssertEqual(session.decodingPolicy, "windows-1252")
        XCTAssertEqual(session.book?.encoding, "windows-1252")
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "windows-1252")
        XCTAssertEqual(try core.sourceFileLocation(fileId: file.id).bookId, current)
        let created = await probe.createdIDs; XCTAssertEqual(created, [current])
        let noOrphans = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.importJobIDs(root)) == [current] }, object: nil)
        await fulfillment(of: [noOrphans], timeout: 5)
        XCTAssertNil(session.error)
        await session.leave().value
    }

    @MainActor func testFailedEncodingRestartReleasesAdmissionWithoutCreatingAnImport() async throws {
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let session = ReaderSession(service: service, activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) }, restartReading: { _, _ in throw CocoaError(.fileReadNoPermission) })
        await session.open(.source(SourceFile(id: file.id, shelfID: "builtin", relativePath: "a.txt")))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil && session.snapshot?.phase == .complete }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let previous = try XCTUnwrap(session.readingID)
        session.restart(encoding: "UTF-8")
        XCTAssertTrue(session.restartingEncoding)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !session.restartingEncoding }, object: nil)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.readingID, previous)
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "auto")
        XCTAssertEqual(try importJobIDs(root), [previous])
        await session.leave().value
    }

    @MainActor func testLeavingDuringEncodingRestartRejectsLateResultsWithoutOrphanJobs() async throws {
        for afterCreation in [false, true] {
            let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
            let entered = expectation(description: "restart held \(afterCreation)")
            let gate = SourceReadinessGate(entered: entered), probe = EncodingRestartProbe(gate: gate, holdAfterCreation: afterCreation)
            let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
            let session = ReaderSession(service: service, activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) }, restartReading: { try await probe.run(service: service, id: $0, encoding: $1) })
            await session.open(.source(SourceFile(id: file.id, shelfID: "builtin", relativePath: "a.txt")))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil && session.snapshot?.phase == .complete }, object: nil)
            await fulfillment(of: [ready], timeout: 5)
            let previous = try XCTUnwrap(session.readingID), policy = session.decodingPolicy
            session.restart(encoding: "UTF-8")
            await fulfillment(of: [entered], timeout: 2)
            await session.leave().value
            await gate.release()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !session.restartingEncoding }, object: nil)
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(session.readingID, previous)
            XCTAssertEqual(session.decodingPolicy, policy)
            XCTAssertNil(session.error)
            let created = await probe.createdIDs
            XCTAssertEqual(created.count, afterCreation ? 1 : 0)
            let noOrphans = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.importJobIDs(root)) == [previous] }, object: nil)
            await fulfillment(of: [noOrphans], timeout: 5)
            for id in created {
                let key = await service.importSourceKey(id)
                XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: key), "Released complete import descriptor must be reclaimed")
            }
            XCTAssertEqual(try core.sourceDecoding(fileId: file.id), afterCreation ? "UTF-8" : "auto")
            withExtendedLifetime(session) {}
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
    }

    @MainActor func testUnavailableEncodingSourceDoesNotBlockReadingOrExposeControls() async throws {
        for scenario in ["missing", "corrupt", "removed-file"] {
            let (root, service, core, _, _, book, _, suite) = try singleBookFixture()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let key = await service.importSourceKey(book.id)
            if scenario == "corrupt" {
                defaults.set(Data("{broken source".utf8), forKey: key)
            } else if scenario == "removed-file" {
                let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
                let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(try JSONEncoder().encode(ImportSource(rootBookmark: bookmark, relativePath: "a.txt", fileID: file.id)), forKey: key)
                try core.scanLibraryShelf(shelfId: "builtin", items: [])
                XCTAssertThrowsError(try core.sourceFileLocation(fileId: file.id))
            }
            let activity = ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) }
            let session = ReaderSession(service: service, activity: activity)
            await session.open(.book(book.id))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window?.projectionAnchor != nil }, object: nil)
            await fulfillment(of: [ready], timeout: 5)
            XCTAssertEqual(session.readingID, book.id, scenario)
            XCTAssertNotNil(session.window, "Monitoring must publish prepared text: \(scenario)")
            XCTAssertNil(session.error, scenario)
            XCTAssertNil(session.decodingPolicy, scenario)
            // Settings' This Book row and More's Change Encoding both use this gate.
            XCTAssertNil(session.encodingLabel, "No actionable encoding control: \(scenario)")
            XCTAssertTrue(session.window?.chunks.contains { !$0.text.isEmpty } == true, scenario)
            await session.leave().value
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
    }

    @MainActor func testCompletedBookEncodingChangeRestoresDataAndPersistsChoice() async throws {
        let (root, service, core, formal, pending, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let path = root.appendingPathComponent("a.txt")
        let original = "Chapter 1\nUn caf\u{e9} original sample.\n" + String(repeating: "Another original paragraph.\n", count: 30)
        try Data(original.utf8).write(to: path)
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let entry = try await service.libraryEntry(file.id)
        func complete(_ lease: ReadingLease) async throws -> ReadingSnapshot {
            try await service.waitForImportsIdle()
            let snapshot = try await service.snapshot(lease.id)
            XCTAssertEqual(snapshot.phase, .complete)
            return snapshot
        }
        let first = try await service.openSourceFile(entry.source)
        let initial = try await complete(first)
        let auto = await service.readingDecoding(first.id); XCTAssertEqual(auto, "auto")
        try await service.savePosition(bookID: first.id, offset: 10)
        _ = try await service.ensureBookmark(first.id, at: 10)
        let edit = try await service.prepareAnnotation(first.id, start: 10, end: 16)
        _ = try await service.saveNote(edit, text: "Original annotation")
        // Both decoders succeed; the second is visibly wrong, so failure-only UI
        // cannot solve this case. Completion must not prevent a new import.
        let changed = try await service.restartImport(first.id, encoding: "windows-1252")
        let changedBook = try await complete(changed)
        XCTAssertNotEqual(changedBook.book.contentSha256, initial.book.contentSha256)
        XCTAssertEqual(changedBook.book.positionUtf8, 0)
        let newMarks = try await service.marks(changed.id, kind: .annotation, offset: 0)
        XCTAssertTrue(newMarks.items.isEmpty)
        let restored = try await service.restartImport(changed.id, encoding: "UTF-8")
        let restoredBook = try await complete(restored)
        XCTAssertEqual(restoredBook.book.contentSha256, initial.book.contentSha256)
        XCTAssertEqual(restoredBook.book.positionUtf8, 10)
        let bookmark = try await service.hasBookmark(restored.id, at: 10); XCTAssertTrue(bookmark)
        let notes = try await service.marks(restored.id, kind: .annotation, offset: 0)
        XCTAssertEqual(notes.items.map(\.note), ["Original annotation"])
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "UTF-8")
        XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
        let reopenedService = ReaderService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite, userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
        let reopened = try await reopenedService.aiPrepare(entry.source)
        let result = try await reopenedService.snapshot(reopened.id)
        XCTAssertEqual(result.book.contentSha256, initial.book.contentSha256)
        XCTAssertEqual(result.book.positionUtf8, 10)
        withExtendedLifetime([first, changed, restored, reopened]) {}
    }

    func testPreparedLocalLibraryRestoresCloudRootBeforeCachedEarlyReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cloud = root.appendingPathComponent("cloud"), suite = "LocalCloudRestore-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: cloud.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), location: "icloud", builtin: true)
        UserDefaults(suiteName: suite)?.set("synthetic-account", forKey: "Moonread.cloudLibraryOwner")
        let service = ReaderService(core: core, sourceDefaultsSuite: suite)
        try core.scanLibraryShelf(shelfId: "builtin", items: [.init(relativePath: "cached.txt", directory: false, size: 10, modified: 0, needsDownload: true)])
        try await service.prepareLocalLibrary(restoreRoot: { $0.restoreCloudLibraryRoot(owner: "synthetic-account") })
        let restored = await service.cloudLibraryRoot
        XCTAssertEqual(restored?.standardizedFileURL, cloud.standardizedFileURL)
        XCTAssertEqual(try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["cached.txt"], "The existing-shelf early return must not enumerate the empty directory or replace its cached index")
    }

    @MainActor func testSettingsMemoryCopyTracksValidatedPersistence() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        var settings = try service.settings(); settings.fontSize = 23; settings.lineSpacing = 9
        try await service.saveSettings(settings)
        XCTAssertEqual(try service.settings(), settings)
        XCTAssertEqual(try decodeReaderSettings(json: UserDefaults(suiteName: suite)!.string(forKey: "Moonread.readerSettings")!), settings)
    }

    func testReadingChangeWaitRegistersAtomicallyAndWakesAllWaiters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let before = await service.readingChangeRevision("book")
        await service.readingChanged("book")
        try await service.waitForChange("book", after: before, timeout: .seconds(5))
        let revision = await service.readingChangeRevision("book")
        let a = Task { try await service.waitForChange("book", after: revision, timeout: .seconds(5)) }
        let b = Task { try await service.waitForChange("book", after: revision, timeout: .seconds(5)) }
        for _ in 0..<100 { if await service.readingWaiterCount("book") == 2 { break }; await Task.yield() }
        let count = await service.readingWaiterCount("book"); XCTAssertEqual(count, 2)
        await service.readingChanged("book")
        try await a.value; try await b.value
        let remaining = await service.readingWaiterCount("book"); XCTAssertEqual(remaining, 0)
    }

    func testReadingWaitCancellationBeforeRegistrationAndTimeoutRaceNeverLeaks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let clock = ManualTestClock()
        for _ in 0..<30 {
            let revision = await service.readingChangeRevision("book")
            let task = Task { try await service.waitForChange("book", after: revision, timeout: .milliseconds(1), sleep: { _ in try await clock.sleep(1) }) }
            task.cancel(); await service.readingChanged("book")
            do { try await task.value; XCTFail("Cancelled waiter returned success") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        }
        let revision = await service.readingChangeRevision("book")
        let timeout = Task { try await service.waitForChange("book", after: revision, timeout: .milliseconds(1), sleep: { _ in try await clock.sleep(1) }) }
        await awaitState { clock.pendingSleeps == 1 }; clock.advance(1)
        try await timeout.value
        let after = await service.readingChangeRevision("book"); XCTAssertEqual(revision, after)
        let remaining = await service.readingWaiterCount("book"); XCTAssertEqual(remaining, 0)
    }

    func testReadingWaitCancellationDoesNotCancelAnotherReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let a = Task { try await service.waitForChange("book", after: 0, timeout: .seconds(5)) }
        let b = Task { try await service.waitForChange("book", after: 0, timeout: .seconds(5)) }
        for _ in 0..<100 { if await service.readingWaiterCount("book") == 2 { break }; await Task.yield() }
        a.cancel(); do { try await a.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let remaining = await service.readingWaiterCount("book"); XCTAssertEqual(remaining, 1)
        await service.readingChanged("book"); try await b.value
    }

    @MainActor func testOpeningAppearanceCompletesOnceAndVisibilityReturnsWithoutNewOpening() {
        let root = UIViewController(), navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(root, animated: false)
        let observer = NavigationTransitionObserver.Controller()
        root.addChild(observer); root.view.addSubview(observer.view); observer.didMove(toParent: root)
        let id = UUID(); var completed: [UUID] = [], visibility: [Bool] = []
        observer.visibilityChanged = { visibility.append($0) }
        observer.setOpening(id, appeared: { value, _ in completed.append(value) })
        observer.viewDidAppear(false)
        observer.viewDidDisappear(false); observer.viewDidAppear(false)
        XCTAssertEqual(completed, [id]); XCTAssertEqual(visibility, [true, false, true])
        let next = UUID(); observer.setOpening(next, appeared: { value, _ in completed.append(value) })
        XCTAssertEqual(completed, [id, next])
    }

    @MainActor func testOpeningThresholdsReadyPriorityAndRenderedPlaceholder() {
        var now = 100.0
        let state = ReaderOpeningState(now: { now }, schedules: false)
        let request = OpeningRequest(target: .book("synthetic"), now: now)
        state.visibility(true, active: true); state.begin(request)
        now = 100.299; state.settled(request.id, reason: "test"); XCTAssertEqual(state.phase, .blank)
        now = 100.301; state.evaluate(); XCTAssertEqual(state.phase, .titlePage); XCTAssertFalse(state.showsProgress)
        now = 100.799; state.evaluate(); XCTAssertFalse(state.showsProgress)
        now = 100.801; state.evaluate(); XCTAssertTrue(state.showsProgress)
        state.update(ready: true, terminal: false); XCTAssertEqual(state.phase, .reading); XCTAssertFalse(state.fadesContent)
        state.begin(OpeningRequest(target: .book("new"), now: now), navigationSettled: true)
        now += 0.5; state.evaluate(); state.placeholderDisplayed(state.request!.id)
        state.update(ready: true, terminal: false); XCTAssertTrue(state.fadesContent)
        state.update(ready: true, terminal: true); XCTAssertEqual(state.phase, .reading)
    }

    @MainActor func testOpeningPushLongerThanFeedbackGateAndReducedMotion() {
        var now = 10.0
        let state = ReaderOpeningState(now: { now }, schedules: false)
        let request = OpeningRequest(target: .book("synthetic"), now: now)
        state.visibility(true, active: true); state.begin(request)
        now += 1.5; state.evaluate(); XCTAssertEqual(state.phase, .blank); XCTAssertFalse(state.showsProgress)
        state.settled(request.id, reason: "test"); XCTAssertEqual(state.phase, .titlePage); XCTAssertTrue(state.showsProgress)
        state.placeholderDisplayed(request.id); state.update(ready: true, terminal: false, reduced: true)
        XCTAssertEqual(state.phase, .reading); XCTAssertFalse(state.fadesContent)
    }

    @MainActor func testOpeningOldAttemptInactiveAndImmediateFailure() {
        var now = 0.0
        let state = ReaderOpeningState(now: { now }, schedules: false)
        let old = OpeningRequest(target: .book("old"), now: now)
        state.visibility(true, active: true); state.begin(old)
        let next = OpeningRequest(target: .book("new"), now: now)
        state.begin(next); state.settled(old.id, reason: "test"); state.placeholderDisplayed(old.id)
        XCTAssertFalse(state.navigationSettled); XCTAssertFalse(state.placeholderShown)
        state.visibility(false, active: false); now = 2; state.evaluate(); XCTAssertEqual(state.phase, .blank)
        state.visibility(true, active: true); state.update(ready: false, terminal: true)
        XCTAssertEqual(state.phase, .titlePage); XCTAssertFalse(state.showsProgress)
        state.begin(OpeningRequest(target: .book("retry"), now: now), navigationSettled: true)
        XCTAssertEqual(state.phase, .blank)
        state.update(ready: true, terminal: false); XCTAssertEqual(state.phase, .reading)
    }

    func testEnglishLocalizationCountsAndImportMessages() throws {
        let bundle = try XCTUnwrap(Bundle(path: try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))))
        func text(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil),
                   locale: Locale(identifier: "en"), arguments: arguments)
        }
        XCTAssertEqual(text("%lld 项", 0), "0 items")
        XCTAssertEqual(text("%lld 项", 1), "1 item")
        XCTAssertEqual(text("%lld 项", 2), "2 items")
        XCTAssertEqual(text("%lld 个连接", 1), "1 connection")
        XCTAssertEqual(text("正在执行 %lld 项操作", 2), "Running 2 operations")
        XCTAssertEqual(text("%lld 个阅读日 · %lld 本书", 1, 2), "1 reading day · 2 books")
        XCTAssertEqual(text("%lld 个阅读日 · %lld 本书", 2, 1), "2 reading days · 1 book")
        XCTAssertEqual(text("%lld 个文件夹 · %lld 个文件", 0, 1), "0 folders · 1 file")
        XCTAssertEqual(text("%llu 本 · %@", 1, "iCloud"), "1 book · iCloud")
        XCTAssertEqual(text("%@ · %lld 个结果", "Shelf", 1), "Shelf · 1 result")
        XCTAssertEqual(text("%@ · %lld 个结果", "Shelf", 2), "Shelf · 2 results")
        // Use the production presenter with English resources, independently of the test runner language.
        XCTAssertEqual(ReaderMessages.error(ReaderError.Decode(message: "opaque diagnostic"), bundle: bundle),
                       "The text encoding could not be read. Try opening it with another encoding.")
        XCTAssertFalse(ReaderMessages.error(ReaderError.Io(message: "opaque diagnostic"), bundle: bundle).contains("opaque diagnostic"))
        XCTAssertEqual(ReaderMessages.error(ReaderError.StoreTooNew(version: 21, current: 20), bundle: bundle),
                       "This data was created by a newer Moonread version. Update the app to open it.")
        XCTAssertEqual(ReaderMessages.error(ReaderError.IncompatibleStore, bundle: bundle),
                       "This data predates the supported version and cannot be opened. The original data has been kept.")
        XCTAssertEqual(text("其他（当前版本不支持）"), "Other (not supported by this version)")
        XCTAssertEqual(text("统计数据来自更新版本，请更新 App。"), "Statistics data comes from a newer version. Update the app.")
        XCTAssertEqual(text("统计不完整：部分记录当前版本无法理解，请更新 App。"), "Statistics are incomplete: some records are not supported by this version. Update the app.")
        XCTAssertNotEqual(text("后续准备中"), "后续准备中")
        XCTAssertEqual(text("封面，%@", "Sample Title"), "Cover, Sample Title")
        XCTAssertEqual(text("移除标签 %@", "Fantasy"), "Remove tag Fantasy")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id: String = try {
            let core = try ReaderCore(dataDirectory: directory.path)
            let control = try core.createImport(title: "Original title")
            try core.failImport(control: control, error: .SourceChanged)
            return control.bookId()
        }()
        let reopened = try ReaderCore(dataDirectory: directory.path)
        let state = try reopened.querySnapshot(json: "{}").readingSnapshot(bookId: id)
        let failure = try XCTUnwrap(state.error)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.book.title, "Original title")
        XCTAssertEqual(ReaderMessages.error(failure, bundle: bundle),
                       text("原文件已变化，之前的正文和阅读位置已保留。"))
        guard case .SourceChanged = failure else { return XCTFail("Reopened error lost its language-independent kind") }
    }

    /// The reader chooses a list before showing it: the first frame has the target title and
    /// never rows of the other mark kind; a new book no longer falls back to chapters.
    @MainActor
    func testLibrarySelectionIsSynchronousAndDropsOtherKindRows() async {
        let tools = ReaderToolsModel()
        tools.select(.notes)
        XCTAssertEqual(tools.tab, .notes)
        XCTAssertTrue(tools.notes.isEmpty); XCTAssertTrue(tools.loadingNotes, "Waits for its own rows")
        let note = ReaderMark(id: "note", kind: .annotation, startUtf8: 0, endUtf8: 4, excerpt: "月光", note: "", created: 1)
        tools.notes = [note]; tools.loadingNotes = false
        tools.select(.notes)
        XCTAssertEqual(tools.notes.map(\.id), ["note"], "The same kind keeps its rows while refreshing")
        tools.select(.chapters)
        XCTAssertEqual(tools.tab, .chapters); XCTAssertEqual(tools.notes.map(\.id), ["note"])
        tools.select(.bookmarks)
        XCTAssertEqual(tools.tab, .bookmarks); XCTAssertEqual(tools.noteKind, .bookmark)
        XCTAssertTrue(tools.notes.isEmpty, "Annotation rows never show under 书签")
        XCTAssertTrue(tools.loadingNotes); XCTAssertFalse(tools.moreNotes)
        await tools.prepare(bookID: "another", currentChapter: 0, library: false)
        XCTAssertEqual(tools.tab, .bookmarks, "A new book keeps the requested list")
    }

    func testPageAccessibilityActionsUseActiveLocalization() {
        XCTAssertEqual(ReadingController.pageActionNames, [String(localized: "上一页"), String(localized: "下一页")])
    }

    func testAnnotationTapUsesFullNativeRangeWithoutShowingHandles() throws {
        let mark = ReaderMark(id: "highlight", kind: .annotation, startUtf8: 0, endUtf8: 9, excerpt: "月亮落", note: "", created: 1)
        let context = AnnotationSelection(start: mark.startUtf8, end: mark.endUtf8, annotations: [mark])
        XCTAssertEqual(ReadingController.annotationRange(context, mapping: TextCoordinates("月亮落在窗边"), base: 0), NSRange(location: 0, length: 3))
        XCTAssertNil(ReadingController.annotationRange(context, mapping: TextCoordinates("另一页"), base: 30))
        let menu = ReadingController().selectionMenu(for: context, suggestedActions: []) { _ in }
        func actions(_ menu: UIMenu) -> [UIAction] { menu.children.flatMap { ($0 as? UIMenu).map(actions) ?? (($0 as? UIAction).map { [$0] } ?? []) } }
        XCTAssertTrue(actions(menu).contains { $0.title == String(localized: "拷贝") })
        XCTAssertTrue(actions(menu).contains { $0.title == String(localized: "编辑批注") })
        XCTAssertTrue(actions(menu).contains { $0.title == String(localized: "移除批注") && $0.attributes.contains(.destructive) })
    }

    @MainActor
    func testSelectionMenuUsesAnyOverlapAndPreservesTheSelectedTextRange() throws {
        let controller = ReadingController()
        let empty = ReaderMark(id: "empty", kind: .annotation, startUtf8: 3, endUtf8: 9, excerpt: "", note: "", created: 2)
        let note = ReaderMark(id: "note", kind: .annotation, startUtf8: 15, endUtf8: 24, excerpt: "", note: "Note", created: 1)
        for (start,end,overlap) in [(0,3,false),(3,9,true),(4,6,true),(0,6,true),(6,12,true),(0,26,true),(9,15,false)] {
            let context = AnnotationSelection(start: UInt64(start), end: UInt64(end), annotations: [empty,note])
            XCTAssertEqual(context.start,UInt64(start)); XCTAssertEqual(context.end,UInt64(end))
            let lookup = UIMenu(title: "Lookup", identifier: .lookup, children: [])
            let menu = controller.selectionMenu(for: context, suggestedActions: [lookup]) { _ in }
            let primary = try XCTUnwrap(menu.children.first as? UIMenu)
            let actions = primary.children.compactMap { $0 as? UIAction }
            XCTAssertEqual(actions.map(\.title), overlap
                ? [String(localized: "编辑批注"),String(localized: "移除批注"),String(localized: "拷贝"),String(localized: "全文搜索")]
                : [String(localized: "标注"),String(localized: "拷贝"),String(localized: "全文搜索")])
            if overlap { XCTAssertTrue(actions[1].attributes.contains(.destructive)) }
            XCTAssertTrue(menu.children.contains { $0 === lookup }, "Preserve deferred native lookup actions")
            // Primary, the native lookup group, then one inline group of notes followed by tools.
            XCTAssertEqual(menu.children.count, 3)
            let reading = try XCTUnwrap(menu.children.last as? UIMenu)
            XCTAssertTrue(reading.options.contains(.displayInline)); XCTAssertEqual(reading.title, "")
            let titles = reading.children.compactMap { ($0 as? UIAction)?.title }
            let notes = overlap ? [String(localized: "批注整段")] : [String(localized: "写批注"), String(localized: "批注整段")]
            XCTAssertEqual(Array(titles.prefix(notes.count + 1)), notes + [String(localized: "从这里跨页选取")])
            XCTAssertEqual(titles.count - notes.count - 1, controller.allowsChapterEditing ? 1 : 0)
        }
    }
    /// 学习…, the speech group and 共享… share one section using the supplied objects; other shapes stay as supplied.
    @MainActor
    func testSelectionMenuJoinsLearnSpeechAndShareOnlyInTheSuppliedShape() throws {
        let controller = ReadingController()
        let context = AnnotationSelection(start: 0, end: 3, annotations: [])
        let learnItem = UICommand(title: "学习…", action: #selector(UIResponderStandardEditActions.select(_:)))
        let shareItem = UICommand(title: "共享…", action: #selector(UIResponderStandardEditActions.selectAll(_:)))
        let lookup = UIMenu(identifier: .lookup, options: .displayInline, children: [])
        let learn = UIMenu(identifier: .learn, options: .displayInline, children: [learnItem])
        let speech = UIMenu(title: "语音", identifier: .speech, options: .displayInline, children: [])
        let share = UIMenu(identifier: .share, options: .displayInline, children: [shareItem])
        func joined(_ menu: UIMenu) -> UIMenu? {
            menu.children.compactMap { $0 as? UIMenu }.first { $0.children.contains { $0 === learnItem } && $0.identifier != .learn }
        }

        let triple = controller.selectionMenu(for: context, suggestedActions: [lookup, learn, speech, share]) { _ in }
        XCTAssertTrue(triple.children[1] === lookup, "Lookup stays the supplied group")
        let group = try XCTUnwrap(joined(triple))
        XCTAssertEqual(group.title, ""); XCTAssertEqual(group.options, .displayInline)
        XCTAssertEqual(group.children.count, 3)
        XCTAssertTrue(group.children[0] === learnItem && group.children[1] === speech && group.children[2] === shareItem)
        XCTAssertFalse(triple.children.contains { $0 === learn || $0 === share || $0 === speech })

        let pair = controller.selectionMenu(for: context, suggestedActions: [learn, share]) { _ in }
        let pairGroup = try XCTUnwrap(joined(pair))
        XCTAssertTrue(pairGroup.children.count == 2 && pairGroup.children[0] === learnItem && pairGroup.children[1] === shareItem)

        let other = UIMenu(identifier: .format, options: .displayInline, children: [])
        let unknown = controller.selectionMenu(for: context, suggestedActions: [learn, other, share]) { _ in }
        XCTAssertNil(joined(unknown), "An unknown group between them leaves both as supplied")
        XCTAssertTrue(unknown.children.contains { $0 === learn } && unknown.children.contains { $0 === share })

        let palette = UIMenu(identifier: .learn, options: [.displayInline, .displayAsPalette], children: [learnItem])
        let shaped = controller.selectionMenu(for: context, suggestedActions: [palette, share]) { _ in }
        XCTAssertTrue(shaped.children.contains { $0 === palette } && shaped.children.contains { $0 === share })
    }

    @MainActor
    func testPartialSelectionOpensOneEditorAndSavesMergedComments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try ReaderCore(dataDirectory: root.path)
        let service = ReaderService(core: core)
        let book = try core.createSampleBook()
        let session = ReaderSession(service: service)
        await session.open(.book(book.id))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let source = try XCTUnwrap(session.window.map { ReadingText($0).text })
        func offset(_ n: Int) -> UInt64 { UInt64(source.prefix(n).utf8.count) }
        let rightEdit = try await service.prepareAnnotation(book.id, start: offset(8), end: offset(12))
        _ = try await service.saveNote(rightEdit, text: "Second comment")
        let leftEdit = try await service.prepareAnnotation(book.id, start: offset(1), end: offset(5))
        let left = try await service.saveNote(leftEdit, text: "First comment")
        let position = session.anchor
        session.selectText(start: offset(4), end: offset(9), action: .comment)
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.editor != nil }, object: nil)
        await fulfillment(of: [opened], timeout: 5)
        let edit = try XCTUnwrap(session.editor)
        XCTAssertEqual(edit.note, "First comment\n\nSecond comment")
        XCTAssertEqual(edit.startUtf8, offset(1)); XCTAssertEqual(edit.endUtf8, offset(12))
        let unchanged = try await service.mark(left.id)
        XCTAssertEqual(unchanged.endUtf8, offset(5), "Opening must not commit range changes")
        _ = try await service.saveNote(edit, text: "Edited together")
        let marks = try await service.marks(book.id, kind: .annotation, offset: 0).items
        XCTAssertEqual(marks.count, 1); XCTAssertEqual(marks.first?.note, "Edited together")
        XCTAssertEqual(session.anchor, position)
        await session.leave().value
    }

    @MainActor
    func testCoverDownsamplingSaveCancelAndHashValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try ReaderCore(dataDirectory: root.path)
        let service = ReaderService(core: core)
        let book = try core.createSampleBook()
        let base = try await service.details(bookID: book.id).metadata
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 3000), format: format).jpegData(withCompressionQuality: 0.95) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        }
        let cover = try await service.makeCover(data)
        XCTAssertEqual(cover.height, 1600); XCTAssertLessThanOrEqual(cover.width, 1600)
        let url = try await service.coverURL(cover)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Selection stays a draft until Save")
        let preview = try await service.coverImage(cover, pixels: 320)
        XCTAssertNotNil(preview)
        var edited = base; edited.cover = cover
        try await service.saveMetadata(base: base, edited: edited)
        let saved = try await service.details(bookID: book.id).metadata
        XCTAssertEqual(saved.cover, cover)
        let persistedCover = try await service.coverImage(cover, pixels: 321)
        XCTAssertNotNil(persistedCover)
        let cancelled = try await service.makeCover(data)
        await service.discardCoverDraft(cancelled)
        let discarded = try await service.coverImage(cancelled, pixels: 123)
        XCTAssertNil(discarded)

    }
    @MainActor
    func testCompleteOutlineSearchFoldingAndRefreshKeepOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("outline.txt")
        let first = "第一卷 夜\n" + (1...100).map { "第\($0)章 月\n正文。\n" }.joined()
        let second = "第二卷 晨\n" + (101...200).map { "第\($0)章 月\n正文。\n" }.joined()
        let source = first + second
        try source.write(to: file, atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "Outline")
        let outline = try core.querySnapshot(json: "{}").chapterOutline(bookId: book.id)
        let current = try XCTUnwrap(outline.items.first { $0.title == "第150章 月" })
        let service = ReaderService(core: core)
        let model = ReaderToolsModel(service: service)
        await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true)
        XCTAssertEqual(model.chapters.count, 202)
        XCTAssertEqual(model.chapterTarget, current.startUtf8)
        model.toggleVolume(0); model.toggleVolume(UInt64(first.utf8.count))
        XCTAssertEqual(model.chapters.count, 2)
        model.filterChapters("150")
        XCTAssertEqual(model.chapters.map(\.startUtf8), [current.startUtf8])
        XCTAssertEqual(model.chapters[0].wordCount, 3)
        model.filterChapters("")
        XCTAssertEqual(model.chapters.count, 102)
        XCTAssertEqual(model.chapterTarget, current.startUtf8)
        let revision = model.chapterJumpRevision
        try await service.correctChapter(book.id, offset: current.startUtf8, title: "第150章 新标题", level: 1)
        await model.refreshChapters()
        XCTAssertEqual(model.chapterJumpRevision, revision, "A refreshed snapshot must not reposition the directory")
        XCTAssertEqual(model.chapters.first { $0.startUtf8 == current.startUtf8 }?.title, "第150章 新标题")
        model.filterChapters("zz-no-match")
        XCTAssertTrue(model.chapters.isEmpty)
        model.showChapter(current.startUtf8)
        XCTAssertEqual(model.chapterTarget, current.startUtf8)
    }

    @MainActor
    func testStatisticsKeepsPausesAndPreviewSeparate() {
        func activity(_ id: String, start: Int64, end: Int64, preview: Bool = false) -> ReadingActivity {
            ReadingActivity(id: id, sessionId: "session", contentKey: "sha", bookId: "book", title: "Book",
                            startedMs: start, endedMs: end, localDay: 20_000, utcOffsetSeconds: 0, preview: preview, startUtf8: 0)
        }
        let spans = StatisticsSpan.merge([
            activity("1", start: 0, end: 15_000), activity("2", start: 15_000, end: 30_000),
            activity("3", start: 31_000, end: 45_000), activity("4", start: 45_000, end: 50_000, preview: true)
        ])
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].milliseconds, 30_000)
        XCTAssertEqual(spans[1].start - spans[0].end, 1_000)
        XCTAssertTrue(spans[2].preview)
        XCTAssertEqual(spans.reduce(0) { $0 + $1.milliseconds }, 49_000)
    }

    @MainActor
    func testStatisticsDayUsesGregorianDateAtReadingLocation() {
        let utc = ISO8601DateFormatter().date(from: "2026-10-01T02:00:00Z")!
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = StatisticsDates.day(utc, calendar: calendar)
        let parts = StatisticsDates.civilCalendar.dateComponents([.year, .month, .day], from: StatisticsDates.date(day))
        XCTAssertEqual(parts.year, 2026); XCTAssertEqual(parts.month, 9); XCTAssertEqual(parts.day, 30)
        XCTAssertEqual(StatisticsDates.duration(59_000), String(localized: "不足 1 分钟"))
    }
    @MainActor
    func testStatisticsRangesUseLocalCalendarDaysIncludingToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; calendar.firstWeekday = 2
        func civil(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
            StatisticsDates.civilDay(StatisticsDates.civilCalendar.date(from: DateComponents(year: y, month: m, day: d))!)
        }
        let today = civil(2026, 10, 5)
        // Seven local days ending with today, independent of the week's start.
        XCTAssertEqual(StatisticsWindow(period: .recent).bounds(today: today, calendar: calendar), civil(2026, 9, 29)...today)
        XCTAssertFalse(StatisticsWindow(period: .recent).canAdvance(today: today))
        // Calendar months and years follow the local calendar, including the evening of the last day.
        let evening = ISO8601DateFormatter().date(from: "2026-09-30T15:30:00Z")! // 23:30 in Shanghai
        var month = StatisticsWindow(period: .month, date: evening)
        XCTAssertEqual(month.bounds(today: today, calendar: calendar), civil(2026, 9, 1)...civil(2026, 9, 30))
        XCTAssertTrue(month.canAdvance(today: today))
        month.shift(1, calendar: calendar)
        XCTAssertEqual(month.bounds(today: today, calendar: calendar), civil(2026, 10, 1)...civil(2026, 10, 31))
        XCTAssertFalse(month.canAdvance(today: today))
        let year = StatisticsWindow(period: .year, date: evening)
        XCTAssertEqual(year.bounds(today: today, calendar: calendar), civil(2026, 1, 1)...civil(2026, 12, 31))
        var recent = StatisticsWindow(period: .recent, date: evening)
        recent.shift(-1, calendar: calendar)
        XCTAssertEqual(recent.date, evening, "The recent window has no history to step through")
    }

    @MainActor
    func testStatisticsBucketsKeepZeroDaysAndOmitFutureMonths() {
        func civil(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
            StatisticsDates.civilDay(StatisticsDates.civilCalendar.date(from: DateComponents(year: y, month: m, day: d))!)
        }
        let today = civil(2026, 10, 5)
        let days = [StatisticsDay(day: civil(2026, 10, 1), durationMs: 60_000, bookCount: 1),
                    StatisticsDay(day: today, durationMs: 120_000, bookCount: 2),
                    StatisticsDay(day: civil(2026, 2, 28), durationMs: 30_000, bookCount: 1),
                    StatisticsDay(day: civil(2024, 6, 1), durationMs: 10_000, bookCount: 1)]
        let week = StatisticsBuckets.days(days, range: (today - 6)...today)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.map(\.durationMs), [0, 0, 60_000, 0, 0, 0, 120_000], "Days without reading stay visible as zero")
        let months = StatisticsBuckets.months(days, year: civil(2026, 1, 1)...civil(2026, 12, 31), today: today)
        XCTAssertEqual(months.count, 10, "Months after the current one have not happened")
        XCTAssertEqual(months[1].first, civil(2026, 2, 1)); XCTAssertEqual(months[1].last, civil(2026, 2, 28))
        XCTAssertEqual(months[1].durationMs, 30_000); XCTAssertEqual(months[9].durationMs, 180_000)
        let years = StatisticsBuckets.years(days, today: today)
        XCTAssertEqual(years.map(\.durationMs), [10_000, 0, 210_000], "Every year from the first reading through now")
        XCTAssertTrue(StatisticsBuckets.years([], today: today).isEmpty)
        XCTAssertEqual(StatisticsDates.axisSteps(72), [0, 30, 60, 90], "Gridlines stay on round minutes")
        XCTAssertEqual(StatisticsDates.axisSteps(148), [0, 60, 120, 180])
    }
    @MainActor func testFastReuseCompletionDoesNotRequestCloudHandoff() async throws {
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let entry = try await service.libraryEntry(file.id)
        let prepared = try await service.aiPrepare(entry.source)
        try await service.waitForImportsIdle()
        let key = SourceContentKey(rawSha256: try CloudDocumentHandoff.bytesHash(root.appendingPathComponent("a.txt")), decoding: "auto")
        let cached = try XCTUnwrap(core.sourceBook(key: key), "The first preparation must populate the raw-SHA reuse cache")
        let before = await service.cloudLibraryScheduleRequests
        let lease = try await service.openSourceFile(entry.source)
        try await service.waitForImportsIdle()
        XCTAssertEqual(try core.importStatus(bookId: lease.id).phase, .complete)
        XCTAssertNotEqual(lease.id, cached.id)
        XCTAssertEqual(try core.sourceFileLocation(fileId: file.id).bookId, cached.id, "Reuse immediately binds the file to the cached canonical book")
        let after = await service.cloudLibraryScheduleRequests
        XCTAssertEqual(after, before, "Reuse completion must not even request a cloud handoff")
        withExtendedLifetime([prepared, lease]) {}
    }

    @MainActor func testCloudPublicationIOWaitDoesNotOccupyReaderActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("handoff actor probe".utf8).write(to: local.appendingPathComponent("book.txt"))
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        var initial: [String:CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &initial, removeOriginals: false,
            persist: { _ in }, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
        let copied = initial, permit = DispatchSemaphore(value: 0)
        let waiting = expectation(description: "I/O is waiting while coordination remains held")
        let publication = Task {
            var receipts = copied
            try await service.publishCloudHandoff(local: local, cloud: cloud, receipts: &receipts, persist: { _ in
                waiting.fulfill(); permit.wait()
            })
        }
        await fulfillment(of: [waiting], timeout: 5)
        let readerEntered = expectation(description: "An unrelated reader job enters the same actor")
        Task { _ = await service.readingChangeRevision("probe"); readerEntered.fulfill() }
        await fulfillment(of: [readerEntered], timeout: 1)
        permit.signal()
        try await publication.value
        XCTAssertEqual(try core.libraryShelves().first?.location, "icloud")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("book.txt").path), "Publication alone never removes originals")
    }

    func testCloudHandoffPendingWorkExecutesAndCompletedRepeatDoesNotCoordinate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CloudNoop-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt")
        try Data("合成交接输入".utf8).write(to: source)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        let roots = CloudLibraryRoots(local: local, cloud: cloud, journal: root.appendingPathComponent("receipts.json"), owner: "synthetic-owner")
        try await service.updateCloudLibrary(roots: roots, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("book.txt").path))
        let first = await service.cloudLibraryPublicationCount; XCTAssertEqual(first, 1)
        // A malformed journal proves the completed repeat does not even read the journal, much less coordinate/enumerate.
        try Data("unread sentinel".utf8).write(to: roots.journal)
        try await service.updateCloudLibrary(roots: roots)
        let repeated = await service.cloudLibraryPublicationCount; XCTAssertEqual(repeated, first)

        // A fresh service recovers an unpublished receipt through the same implementation.
        try Data("new pending input".utf8).write(to: local.appendingPathComponent("next.txt"))
        let intent = CloudHandoffReceipt(bytesHash: try CloudDocumentHandoff.bytesHash(local.appendingPathComponent("next.txt")))
        try JSONEncoder().encode(["next.txt": intent]).write(to: roots.journal)
        let restarted = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        await restarted.restoreCloudLibraryRoot(owner: roots.owner)
        try await restarted.updateCloudLibrary(roots: roots, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
        let recovered = await restarted.cloudLibraryPublicationCount; XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("next.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("next.txt").path))
        XCTAssertTrue(try JSONDecoder().decode([String:CloudHandoffReceipt].self, from: Data(contentsOf: roots.journal)).isEmpty)
    }

    func testCloudHandoffIntentSurvivesCopyBeforeReceiptCompletion() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt"), target = cloud.appendingPathComponent("book.txt")
        try Data("verified copy".utf8).write(to: source)
        var receipts: [String:CloudHandoffReceipt] = [:], durable: [String:CloudHandoffReceipt] = [:]
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
            persist: { value in
                if value.values.contains(where: { $0.copied }) { throw CocoaError(.fileWriteOutOfSpace) }
                durable = value
            }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) }))
        XCTAssertTrue(fm.fileExists(atPath: target.path)); XCTAssertTrue(fm.fileExists(atPath: source.path))
        receipts = try JSONDecoder().decode([String:CloudHandoffReceipt].self, from: JSONEncoder().encode(durable))
        XCTAssertEqual(receipts["book.txt"]?.copied, false)
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
            persist: { durable = $0 }, makeUbiquitous: { _, _ in XCTFail("A proven copy must not be duplicated") })
        XCTAssertEqual(receipts["book.txt"]?.copied, true)
        XCTAssertEqual(try Data(contentsOf: target),Data("verified copy".utf8))
        // Later modification must not be blessed by an old completed receipt.
        try Data("changed copy".utf8).write(to: target)
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in }))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testCloudHandoffPublishesBusinessIdentityBeforeOpeningAndResumesPartialCleanup() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Handoff-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt"), second = local.appendingPathComponent("second.txt")
        try "第一章 月光\n\n这是合成交接测试正文。\n".write(to: source, atomically: true, encoding: .utf8)
        try Data("another unknown file".utf8).write(to: second)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        try await service.prepareLibrary()
        try await service.scanLibraryShelf("builtin")
        let entry = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first { $0.name == "book.txt" })
        let book = try core.importBook(filePath: source.path,title: "Synthetic")

        try core.linkLibraryFile(fileId: entry.id,bookId: book.id)
        try await service.savePosition(bookID: book.id,offset: 9)
        let base = try await service.details(bookID: book.id).metadata
        var edited = base; edited.author = "合成作者"
        try await service.saveMetadata(base: base,edited: edited)
        let indexed = Dictionary(uniqueKeysWithValues: try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").map { ($0.relativePath,$0.id) })
        var receipts: [String:CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local,cloud: cloud,receipts: &receipts,removeOriginals: false,
            capture: { path,version in guard let id = indexed[path] else { return nil }; return HandoffAssociation(fileID: id, bookID: try core.sourceFileLocation(fileId: id).bookId, decoding: try core.sourceDecoding(fileId: id)) },
            persist: { _ in },makeUbiquitous: { try fm.moveItem(at: $0,to: $1) })
        // Process stopped after copying, before the index transaction. Reuse durable evidence.
        let copiedJournal = try JSONEncoder().encode(receipts)
        do {
            try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            XCTFail("Expected interruption after index commit")
        } catch { XCTAssertTrue(fm.fileExists(atPath: source.path)) }
        receipts = try JSONDecoder().decode([String:CloudHandoffReceipt].self,from: copiedJournal)
        try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        let committedJournal = try JSONEncoder().encode(receipts)
        let migrated = try await service.libraryEntry(entry.id)
        XCTAssertEqual(migrated.bookId,book.id); XCTAssertEqual(migrated.positionUtf8,9)
        XCTAssertEqual(migrated.metadata?.author,"合成作者")
        let recent = try await service.recentLibrary(); XCTAssertEqual(recent.first?.id,entry.id)
        XCTAssertEqual(try core.libraryShelves().first?.location,"icloud")
        // Interrupt cleanup after one original is gone, then retry index + cleanup.
        try fm.removeItem(at: source)
        let owner = UUID().uuidString
        UserDefaults(suiteName: suite)?.set(owner,forKey: "Moonread.cloudLibraryOwner")
        let reopenedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let restarted = ReaderService(core: reopenedCore,libraryDirectory: local,sourceDefaultsSuite: suite)
        await restarted.restoreCloudLibraryRoot(owner: owner)
        try await restarted.refreshLibraryShelf("builtin")
        let afterRestart = try await restarted.libraryEntry(entry.id)
        XCTAssertEqual(afterRestart.bookId,book.id); XCTAssertEqual(afterRestart.positionUtf8,9)
        receipts = try JSONDecoder().decode([String:CloudHandoffReceipt].self,from: JSONEncoder().encode(receipts))
        try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        try CloudDocumentHandoff.cleanup(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        XCTAssertTrue(receipts.isEmpty); XCTAssertFalse(fm.fileExists(atPath: second.path))
        let afterCleanup = try await service.libraryEntry(entry.id); XCTAssertEqual(afterCleanup.positionUtf8,9)
        XCTAssertTrue(fm.fileExists(atPath: cloud.appendingPathComponent("book.txt").path))
        try Data("modified after migration".utf8).write(to: cloud.appendingPathComponent("book.txt"))
        receipts = try JSONDecoder().decode([String:CloudHandoffReceipt].self,from: committedJournal)
        do {
            try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
            XCTFail("An old receipt must not re-associate a modified destination")
        } catch { }
        try await service.refreshLibraryShelf("builtin")
        let changed = try await service.libraryEntry(entry.id); XCTAssertEqual(changed.bookId,book.id)
        let independent = try await service.snapshot(book.id); XCTAssertEqual(independent.book.positionUtf8,9)
    }

    func testHandoffRetainsLastKnownAssociationUntilOpen() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try fm.createDirectory(at: local,withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt")
        try Data("old known text".utf8).write(to: source)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core,libraryDirectory: local,sourceDefaultsSuite: "Changed-\(UUID().uuidString)")
        try await service.prepareLibrary()
        try await service.scanLibraryShelf("builtin")
        let entry = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
        let old = try core.importBook(filePath: source.path,title: "Old")
        try core.linkLibraryFile(fileId: entry.id,bookId: old.id)
        try Data("new unknown text".utf8).write(to: source)
        var receipts: [String:CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local,cloud: cloud,receipts: &receipts,removeOriginals: false,
            capture: { _,version in HandoffAssociation(fileID: entry.id, bookID: try core.sourceFileLocation(fileId: entry.id).bookId, decoding: try core.sourceDecoding(fileId: entry.id)) },persist: { _ in },makeUbiquitous: { try fm.moveItem(at: $0,to: $1) })
        XCTAssertEqual(receipts["book.txt"]?.association?.bookID, old.id)
        try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        let unknown = try await service.libraryEntry(entry.id); XCTAssertEqual(unknown.bookId, old.id)
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("book.txt")),Data("new unknown text".utf8))
    }

    private static func pausedSourceFixture() async throws -> (URL, ReaderService, ReaderCore, SourceFile, String, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt")
        try "第一章 月光\n这是暂停语义的原创合成正文。\n".write(to: source, atomically: true, encoding: .utf8)
        let suite = "PauseIntent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        let entry = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
        let control = try core.createImport(title: "暂停语义样本"), id = control.bookId()
        try core.streamImport(control: control, filePath: source.path,
                              expectedRawSha256: CloudDocumentHandoff.bytesHash(source), encodingOverride: "UTF-8")
        control.pause(); try core.failImport(control: control, error: .Paused)
        try core.linkLibraryFile(fileId: entry.id, bookId: id)
        let sourceKey = "Moonread.sourceDraft.library." + entry.id
        let bookmark = try local.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let descriptor = ImportSource(rootBookmark: bookmark, relativePath: "book.txt", encoding: "UTF-8", sourceKey: sourceKey, fileID: entry.id)
        defaults.set(try JSONEncoder().encode(descriptor), forKey: "Moonread.importSource.library." + id)
        defaults.set(id, forKey: sourceKey)
        return (root, service, core, entry.source, id, defaults, suite)
    }

    @MainActor private func waitForMetadataPreparation(_ model: BookInformationModel, until condition: @escaping @MainActor () -> Bool) async throws {
        await awaitState(condition); XCTAssertTrue(condition())
    }

    @MainActor func testMetadataEditingPreservesUserPauseUntilResumePreparation() async throws {
        for fromReader in [false, true] {
            let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            await service.pauseImport(id, reason: .user)
            let target = StatisticsRoute(bookID: id, title: "暂停语义样本", fileID: source.id, fromReader: fromReader)
            let model = BookInformationModel(service: service)
            await model.load(target)
            model.edit(target)
            try await waitForMetadataPreparation(model) { model.preparationPaused || model.error != nil }
            XCTAssertNil(model.error); XCTAssertTrue(model.preparationPaused); XCTAssertNil(model.draft)
            XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
            XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))
            let running = await service.hasRunningImports; XCTAssertFalse(running)
            model.resumePreparation()
            try await waitForMetadataPreparation(model) { !model.preparing }
            XCTAssertNil(model.error); XCTAssertNotNil(model.draft); XCTAssertFalse(model.preparationPaused)
            XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)
            XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
        }
    }

    @MainActor func testMetadataEditingAutomaticallyResumesSystemPausedPreparation() async throws {
        let (root, service, core, _, id, defaults, suite) = try await Self.pausedSourceFixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let target = StatisticsRoute(bookID: id, title: "暂停语义样本", fromReader: true)
        let model = BookInformationModel(service: service)
        await model.load(target)
        model.edit(target)
        try await waitForMetadataPreparation(model) { !model.preparing }
        XCTAssertNil(model.error); XCTAssertNotNil(model.draft); XCTAssertFalse(model.preparationPaused)
        XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)
    }

    @MainActor func testCancellingMetadataPreparationKeepsUserPause() async throws {
        let (root, service, core, _, id, defaults, suite) = try await Self.pausedSourceFixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        await service.pauseImport(id, reason: .user)
        let target = StatisticsRoute(bookID: id, title: "暂停语义样本", fromReader: true)
        let model = BookInformationModel(service: service)
        await model.load(target)
        model.edit(target)
        try await waitForMetadataPreparation(model) { model.preparationPaused || model.error != nil }
        XCTAssertTrue(model.preparationPaused); XCTAssertNil(model.error)
        model.cancelPreparation()
        try await waitForMetadataPreparation(model) { !model.preparing }
        XCTAssertNil(model.draft); XCTAssertNil(model.error)
        XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
        XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))
    }

    func testUserPausedImportStaysPausedAcrossReopenAndRestartUntilExplicitResume() async throws {
        let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        await service.pauseImport(id, reason: .user)
        XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))
        await service.pauseImports(); await service.resumePausedImports()
        let first = try await service.openSourceFile(source)
        XCTAssertEqual(first.id, id)
        XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
        let restartedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let restarted = ReaderService(core: restartedCore, libraryDirectory: root.appendingPathComponent("local"), sourceDefaultsSuite: suite)
        let reopened = try await restarted.openSourceFile(source)
        XCTAssertEqual(reopened.id, id)
        XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .paused)
        let running = await restarted.hasRunningImports; XCTAssertFalse(running)
        try await restarted.resumeImport(id)
        XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
        try await restarted.waitForImportFinish(id)
        XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .complete)
        withExtendedLifetime((first, reopened)) {}
    }

    func testSystemInterruptedImportAutomaticallyResumesOnReopen() async throws {
        do {
            let (root, _, _, source, id, defaults, suite) = try await Self.pausedSourceFixture()
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            let restartedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
            let restarted = ReaderService(core: restartedCore, libraryDirectory: root.appendingPathComponent("local"), sourceDefaultsSuite: suite)
            let lease = try await restarted.openSourceFile(source)
            XCTAssertEqual(lease.id, id)
            try await restarted.waitForImportFinish(id)
            XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .complete)
            XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
            withExtendedLifetime(lease) {}
        }
    }

    func testUserPauseMarkerClearsOnEncodingRestartAndCompletedReclamation() async throws {
        let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        await service.pauseImport(id, reason: .user)
        let lease = try await service.restartImport(id, encoding: "UTF-8")
        XCTAssertNotEqual(lease.id, id)
        XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
        try await service.waitForImportFinish(lease.id)
        XCTAssertEqual(try core.importStatus(bookId: lease.id).phase, .complete)
        // Simulate a crash between completing the cache transaction and clearing
        // the device-only flag. Startup reclamation must repair that residue.
        let completedKey = "Moonread.importUserPaused.v1.library." + lease.id
        defaults.set(true, forKey: completedKey)
        let discardedKey = "Moonread.importUserPaused.v1.library.discarded-task"
        defaults.set(true, forKey: discardedKey)
        let other = try core.createImport(title: "另一本暂停样本")
        await service.pauseImport(other.bookId(), reason: .user)
        try await service.reclaimImports(core)
        XCTAssertNil(defaults.object(forKey: completedKey))
        XCTAssertNil(defaults.object(forKey: discardedKey))
        XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + other.bookId()))
        let current = try await service.openSourceFile(source)
        XCTAssertNotEqual(current.id, id)
        try await service.waitForImportFinish(current.id)
        withExtendedLifetime((lease, current)) {}
    }

    func testPausedImportHandoffResumesAndPromotesPendingReadingData() async throws {
        for preparedPrefix in [false,true] {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PausedHandoff-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try fm.createDirectory(at: local,withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt")
        try "第一章 月\n暂停任务的合成正文。\n".write(to: source,atomically: true,encoding: .utf8)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core,libraryDirectory: local,sourceDefaultsSuite: suite)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        let entry = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)

        let control = try core.createImport(title: "Paused"), pending = control.bookId()
        if preparedPrefix { try core.streamImport(control: control,filePath: source.path,expectedRawSha256: CloudDocumentHandoff.bytesHash(source),encodingOverride: "utf-8") }
        control.pause(); try core.failImport(control: control, error: .Paused)
        try core.linkLibraryFile(fileId: entry.id,bookId: pending)
        let bookmark = try local.bookmarkData(options: .minimalBookmark,includingResourceValuesForKeys: nil,relativeTo: nil)
        let descriptor: [String:Any] = ["rootBookmark":bookmark.base64EncodedString(),"relativePath":"book.txt","fileID":entry.id,"encoding":"utf-8"]
        defaults.set(try JSONSerialization.data(withJSONObject: descriptor),forKey: "Moonread.importSource.library." + pending)
        let expectedOffset: UInt64 = preparedPrefix ? 9 : 0
        try await service.savePosition(bookID: pending,offset: expectedOffset)
        var receipts: [String:CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local,cloud: cloud,receipts: &receipts,removeOriginals: false,
            capture: { _,version in HandoffAssociation(fileID: entry.id, bookID: try core.sourceFileLocation(fileId: entry.id).bookId, decoding: try core.sourceDecoding(fileId: entry.id)) },persist: { _ in },makeUbiquitous: { try fm.moveItem(at: $0,to: $1) })
        try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        try CloudDocumentHandoff.cleanup(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        try await service.resumeImport(pending)
        try await service.waitForImportFinish(pending)
        let completed = try await service.snapshot(pending)
        XCTAssertEqual(completed.phase,.complete); XCTAssertFalse(completed.book.contentSha256.hasPrefix("pending:"))
        XCTAssertEqual(completed.book.positionUtf8,expectedOffset)
        let migrated = try await service.libraryEntry(entry.id)
        XCTAssertEqual(migrated.bookId,completed.book.id); XCTAssertEqual(migrated.positionUtf8,expectedOffset)
        }
    }

    func testPausedImportMovesAndResumesWithoutReopeningIncludingRestart() async throws {
        for restart in [false, true] {
            let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "MovedImport-\(UUID().uuidString)"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
            let local = root.appendingPathComponent("local"), other = root.appendingPathComponent("other")
            try fm.createDirectory(at: local, withIntermediateDirectories: true)
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            let source = local.appendingPathComponent("book.txt")
            try Data("第一章 合成\n保留暂停任务和位置。".utf8).write(to: source)
            let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
            let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
            try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
            let entry = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
            let token = try core.createImport(title: "Paused"), id = token.bookId()
            try core.streamImport(control: token, filePath: source.path, expectedRawSha256: CloudDocumentHandoff.bytesHash(source), encodingOverride: nil)
            token.pause(); try core.failImport(control: token, error: .Paused)
            try core.linkLibraryFile(fileId: entry.id, bookId: id)
            let bookmark = try local.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let descriptor: [String:Any] = ["rootBookmark":bookmark.base64EncodedString(),"relativePath":"book.txt","fileID":entry.id]
            UserDefaults(suiteName: suite)?.set(try JSONSerialization.data(withJSONObject: descriptor), forKey: "Moonread.importSource.library." + id)
            try await service.savePosition(bookID: id, offset: 9)
            let shelf = try await service.registerLibraryShelf(other)
            try await service.moveLibraryItem(entry, to: LibraryLocation(shelfID: shelf), name: "moved.txt", replace: false)
            let resumed = restart ? ReaderService(core: try ReaderCore(dataDirectory: root.appendingPathComponent("db").path), libraryDirectory: local, sourceDefaultsSuite: suite) : service
            try await resumed.resumeImport(id)
            try await resumed.waitForImportFinish(id)
            let result = try await resumed.snapshot(id)
            XCTAssertEqual(result.phase, .complete); XCTAssertEqual(result.book.positionUtf8, 9)
            let linked = try await resumed.libraryEntry(entry.id)
            XCTAssertEqual(linked.bookId, result.book.id); XCTAssertEqual(linked.relativePath, "moved.txt")
        }
    }

    func testExternalRenameReopensCanonicalAndChangedBytesPreserveOldUserData() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ExternalSHA-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt"), moved = local.appendingPathComponent("moved.txt")
        try Data("第一章 合成\n原始正文甲。".utf8).write(to: source)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        let first = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
        let lease = try await service.aiPrepare(first.source)
        let original = try await service.snapshot(lease.id).book
        try await service.savePosition(bookID: lease.id, offset: 9)
        _ = try await service.toggleBookmark(original.id, at: 9)
        try fm.moveItem(at: source, to: moved)
        try await service.refreshLibraryShelf("builtin")
        XCTAssertThrowsError(try core.sourceFileLocation(fileId: first.id))
        let renamed = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
        XCTAssertNil(renamed.bookId)
        let reopened = try await service.aiPrepare(renamed.source)
        let same = try await service.snapshot(reopened.id).book
        XCTAssertEqual(same.contentSha256, original.contentSha256); XCTAssertEqual(same.positionUtf8, 9)
        try Data("第一章 合成\n替换正文乙。".utf8).write(to: moved)
        try await service.refreshLibraryShelf("builtin")
        let stale = try await service.libraryEntry(renamed.id); XCTAssertEqual(stale.bookId, original.id)
        let replacement = try await service.aiPrepare(stale.source)
        let changed = try await service.snapshot(replacement.id).book
        XCTAssertNotEqual(changed.contentSha256, original.contentSha256)
        let old = try await service.snapshot(original.id)
        XCTAssertEqual(old.book.positionUtf8, 9)
        let kept = try await service.hasBookmark(original.id, at: 9); XCTAssertTrue(kept)
        withExtendedLifetime([lease, reopened, replacement]) {}
    }

    func testHandoffKeepsLocalRootWhenNewFileAppearsBeforePublicationAndCanRetry() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        try fm.createDirectory(at: local,withIntermediateDirectories: true)
        try Data("first".utf8).write(to: local.appendingPathComponent("first.txt"))
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core,libraryDirectory: local,sourceDefaultsSuite: "NewFile-\(UUID().uuidString)")
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        var receipts: [String:CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local,cloud: cloud,receipts: &receipts,removeOriginals: false,
            persist: { _ in },makeUbiquitous: { try fm.moveItem(at: $0,to: $1) })
        try Data("newly added".utf8).write(to: local.appendingPathComponent("second.txt"))
        do {
            try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
            XCTFail("Do not activate a root that would hide an untransferred file")
        } catch { }
        XCTAssertEqual(try core.libraryShelves().first?.location,"local")
        XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("second.txt").path))
        try await service.scanLibraryShelf("builtin")
        let first = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first { $0.name == "first.txt" })
        let book = try core.importBook(filePath: local.appendingPathComponent("first.txt").path,title: "Now identified")

try core.linkLibraryFile(fileId: first.id,bookId: book.id)
        try CloudDocumentHandoff.transfer(local: local,cloud: cloud,receipts: &receipts,removeOriginals: false,
            persist: { _ in },makeUbiquitous: { try fm.moveItem(at: $0,to: $1) })
        try await service.publishCloudHandoff(local: local,cloud: cloud,receipts: &receipts,persist: { _ in })
        let resolved = try await service.libraryEntry(first.id); XCTAssertEqual(resolved.bookId,book.id)
        XCTAssertEqual(try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").count,2)
    }

    func testManagedFolderMoveRetainsLastKnownAssociations() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), folder = local.appendingPathComponent("folder"), external = root.appendingPathComponent("external")
        try fm.createDirectory(at: folder,withIntermediateDirectories: true); try fm.createDirectory(at: external,withIntermediateDirectories: true)
        let known = folder.appendingPathComponent("known.txt"), changed = folder.appendingPathComponent("changed.txt")
        try Data("verified child text".utf8).write(to: known); try Data("old child text".utf8).write(to: changed)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core,libraryDirectory: local,sourceDefaultsSuite: "FolderMove-\(UUID().uuidString)")
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        let children = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
        var knownID = "", knownBook = ""
        for child in children {
            let file = local.appendingPathComponent(child.relativePath)
            let book = try core.importBook(filePath: file.path,title: child.name)
            try core.linkLibraryFile(fileId: child.id,bookId: book.id)
            if child.name == "known.txt" { knownID = child.id; knownBook = book.id }
        }
        try await service.savePosition(bookID: knownBook,offset: 4)
        try Data("externally modified child".utf8).write(to: changed)
        let entry = try XCTUnwrap(core.querySnapshot(json: "{}").libraryEntries(shelfId: "builtin",parentPath: "",sort: .name).first)
        let externalID = try await service.registerLibraryShelf(external)
        try await service.moveLibraryItem(entry,to: LibraryLocation(shelfID: externalID),replace: false)
        let valid = try await service.libraryEntry(knownID)
        XCTAssertEqual(valid.bookId,knownBook); XCTAssertEqual(valid.positionUtf8,4)
        let unknown = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: externalID).first { $0.name == "changed.txt" })
        XCTAssertNotNil(unknown.bookId)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("folder/changed.txt")),Data("externally modified child".utf8))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testByteValidationAllowsParentAliasesAndRejectsLeafSymlinks() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try fm.createDirectory(at: real,withIntermediateDirectories: true)
        let file = real.appendingPathComponent("book.txt")
        try Data("same file".utf8).write(to: file)
        try fm.createSymbolicLink(at: alias,withDestinationURL: real)
        let expected = try CloudDocumentHandoff.bytesHash(file)
        XCTAssertNoThrow(try CloudDocumentHandoff.verifyBytes(alias.appendingPathComponent("book.txt"), expectedHash: expected))
        let leaf = real.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: leaf,withDestinationURL: file)
        XCTAssertThrowsError(try CloudDocumentHandoff.verifyBytes(leaf, expectedHash: expected))
    }

    func testCloudHandoffRebindsPausedSourcesBeforeRemovingOriginals() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        let suite = "CloudSourceTest-\(UUID().uuidString)", key = "Moonread.importSource.library.task"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt")
        try Data("original".utf8).write(to: source)
        let bookmark = try local.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let descriptor: [String: Any] = ["rootBookmark": bookmark.base64EncodedString(), "relativePath": "book.txt", "encoding": "gb18030"]
        defaults.set(try JSONSerialization.data(withJSONObject: descriptor), forKey: key)
        var receipts: [String: CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
            persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        try await service.publishCloudHandoff(local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
        let moved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(moved["rootBookmark"] as? String)))
        var stale = false
        let restored = try URL(resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale)
        XCTAssertEqual(restored.standardizedFileURL, cloud.standardizedFileURL)
        XCTAssertEqual(moved["relativePath"] as? String, "book.txt")
        XCTAssertEqual(moved["encoding"] as? String, "gb18030")
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("book.txt")), Data("original".utf8))
    }

    func testCloudRootRestoresAfterActivationWithInterruptedLocalCleanup() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        let suite = "CloudRestoreTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: local.appendingPathComponent("first.txt"))
        try Data("two".utf8).write(to: local.appendingPathComponent("second.txt"))
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        var receipts: [String: CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts,
            removeOriginals: false, persist: { _ in },
            makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
        let bookmark = try cloud.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: bookmark, location: "icloud", builtin: true)
        defaults.set("account", forKey: "Moonread.cloudLibraryOwner")
        // Simulate termination after deleting only the first original.
        try fm.removeItem(at: local.appendingPathComponent("first.txt"))
        let restarted = ReaderService(core: core, sourceDefaultsSuite: suite)
        await restarted.restoreCloudLibraryRoot(owner: "account")
        let recoveredRoot = await restarted.cloudLibraryRoot
        let restored = try XCTUnwrap(recoveredRoot)
        XCTAssertEqual(restored.standardizedFileURL, cloud.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("first.txt")), Data("one".utf8))
        XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("second.txt").path))
        // Recovery cannot bind a different or signed-out account to this root.
        await restarted.restoreCloudLibraryRoot(owner: "other-account")
        let otherRoot = await restarted.cloudLibraryRoot
        XCTAssertNil(otherRoot)
        await restarted.restoreCloudLibraryRoot(owner: nil)
        let signedOutRoot = await restarted.cloudLibraryRoot
        XCTAssertNil(signedOutRoot)
        let shelf = try XCTUnwrap(core.libraryShelves().first)
        XCTAssertEqual(shelf.location, "icloud")
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: bookmark, location: "local", builtin: true)
        await restarted.restoreCloudLibraryRoot(owner: "account")
        let unactivatedRoot = await restarted.cloudLibraryRoot
        XCTAssertNil(unactivatedRoot)
    }

    func testCloudHandoffKeepsOriginalsOnFailureAndResumesFromReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: local.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let first = local.appendingPathComponent("first.txt"), second = local.appendingPathComponent("folder/second.txt")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        var receipts: [String: CloudHandoffReceipt] = [:]
        var activated = false
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in }, activate: { activated = true }, makeUbiquitous: { source, target in
            if target.lastPathComponent == "second.txt" { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.moveItem(at: source, to: target)
        }))
        XCTAssertFalse(activated)
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        // Round-trip the durable receipt, as on a process restart.
        receipts = try JSONDecoder().decode([String: CloudHandoffReceipt].self, from: JSONEncoder().encode(receipts))
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in }, activate: { activated = true }, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
        XCTAssertTrue(activated); XCTAssertTrue(receipts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("first.txt")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("folder/second.txt")), Data("two".utf8))
    }

    func testCloudHandoffRequiresExplicitReplacementAndProtectsChangedOriginal() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("book.txt"), target = cloud.appendingPathComponent("book.txt")
        try Data("local".utf8).write(to: source); try Data("cloud".utf8).write(to: target)
        var receipts: [String: CloudHandoffReceipt] = [:]
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in })) { error in
            XCTAssertEqual((error as? CloudLibraryConflict)?.path, "book.txt")
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("local".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("cloud".utf8))
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, replacing: ["book.txt"], persist: { _ in })
        XCTAssertEqual(try Data(contentsOf: target), Data("local".utf8))
        XCTAssertFalse(fm.fileExists(atPath: source.path))

        try Data("before".utf8).write(to: source); try fm.removeItem(at: target)
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in }, makeUbiquitous: { staged, destination in
            try fm.moveItem(at: staged, to: destination)
            try Data("changed during handoff".utf8).write(to: source)
        }))
        XCTAssertEqual(try Data(contentsOf: source), Data("changed during handoff".utf8))
        try fm.removeItem(at: target)
        XCTAssertThrowsError(try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, persist: { _ in }, makeUbiquitous: { _, _ in XCTFail("A deleted destination must not be recreated") }))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    @MainActor func testFolderPickerEntersShelfBeforeScanAndDoesNotReplayOnCancel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("第一章\n正文".utf8).write(to: folder.appendingPathComponent("小说.txt"))
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
                                    libraryDirectory: directory.appendingPathComponent("books"))
        try await service.prepareLibrary()
        let entered = expectation(description: "Scanning selected shelf")
        let gate = SourceReadinessGate(entered: entered)
        let model = LibraryModel(service: service, scanShelf: { id in
            await gate.wait(); try await service.scanLibraryShelf(id)
        })
        model.selectedTab = .library; model.path = [.manage]
        model.chooseFiles(.folder(nil))
        // Match the system order: presentation ends before the result arrives.
        model.filePickerPresented = false
        model.completeFilePicker(.success([folder]))
        XCTAssertTrue(model.processingFiles)
        await fulfillment(of: [entered], timeout: 2)
        let shelf = try XCTUnwrap(model.shelves.first { $0.name == "selected" })
        let location = LibraryLocation(shelfID: shelf.id)
        XCTAssertEqual(model.path, [.manage, .folder(location)])
        XCTAssertNotNil(model.shelfScans[shelf.id])
        XCTAssertFalse(model.processingFiles, "The destination owns scan feedback after registration")
        let before = try await service.libraryEntries(location)
        XCTAssertTrue(before.isEmpty, "The page can query while scanning is in flight")
        XCTAssertNil(model.afterSheetDismiss)
        await gate.release()
        try await waitForLibraryState { model.shelfScans.isEmpty }
        let entries = try await service.libraryEntries(location)
        XCTAssertEqual(entries.map(\.name), ["小说.txt"])
        model.path = [.manage]
        model.chooseFiles(.folder(nil)); model.cancelFilePicker()
        model.sheetDidDismiss()
        model.completeFilePicker(.success([folder]))
        await Task.yield()
        XCTAssertEqual(model.path, [.manage], "Cancellation cannot resume an earlier selection")
        XCTAssertNil(model.filePicker)
        XCTAssertFalse(model.processingFiles)
    }

    @MainActor func testFilePickerImportsWithoutSheetDismissalAndCanRetryAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = directory.appendingPathComponent("books")
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path), libraryDirectory: books)
        try await service.prepareLibrary()
        let model = LibraryModel(service: service)
        let destination = LibraryLocation(shelfID: "builtin")
        model.chooseFiles(.novels(destination))
        model.completeFilePicker(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertNotNil(model.error); XCTAssertNil(model.filePicker)
        model.error = nil
        let files = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("第一章\n正文".utf8).write(to: file) }
        model.chooseFiles(.novels(destination)); model.filePickerPresented = false
        model.completeFilePicker(.success(files))
        XCTAssertTrue(model.processingFiles, "Explicit import responds before its worker starts")
        try await waitForLibraryState { !model.processingFiles }
        XCTAssertNil(model.error); XCTAssertNil(model.afterSheetDismiss)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: books.appendingPathComponent(file.lastPathComponent).path)) }
        XCTAssertEqual(model.path, [.folder(destination)])
    }

    @MainActor func testImportResultSheetDismissalClearsFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
                                    libraryDirectory: directory.appendingPathComponent("books"))
        try await service.prepareLibrary()
        let model = LibraryModel(service: service)
        model.receive([directory.appendingPathComponent("missing.txt")])
        try await waitForLibraryState { model.sheet?.id == "import-results" && model.importFailures.count == 1 }
        // Both the Done button and interactive dismissal clear the sheet binding.
        // Exercise the real SwiftUI onDismiss callback without pressing Done.
        model.sheet = nil; model.sheetDidDismiss()
        try await waitForLibraryState { model.importFailures.isEmpty }
        XCTAssertNil(model.afterSheetDismiss)
    }

    @MainActor func testImportResultRetryPreservesRemainingFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = directory.appendingPathComponent("books")
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path), libraryDirectory: books)
        try await service.prepareLibrary()
        let model = LibraryModel(service: service)
        let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
        model.receive([first, second])
        try await waitForLibraryState { model.sheet?.id == "import-results" }
        XCTAssertEqual(model.importFailures.count, 2)
        let retry = try XCTUnwrap(model.importFailures.first)
        model.runAfterSheetDismiss { model.retryImport(retry) }
        model.sheetDidDismiss()
        XCTAssertNil(model.afterSheetDismiss)
        XCTAssertEqual(model.importFailures.map(\.url), [second], "A retry must keep the other failed files available")
        try await waitForLibraryState { model.sheet?.id == "import-results" }
        XCTAssertEqual(Set(model.importFailures.map(\.url)), [first, second], "A failed retry returns to the results")

        try "第一章\n月光下的故事。".write(to: first, atomically: true, encoding: .utf8)
        let recovered = try XCTUnwrap(model.importFailures.first { $0.url == first })
        model.runAfterSheetDismiss { model.retryImport(recovered) }
        model.sheetDidDismiss()
        try await waitForLibraryState { model.sheet?.id == "import-results" }
        XCTAssertTrue(FileManager.default.fileExists(atPath: books.appendingPathComponent("first.txt").path))
        XCTAssertEqual(model.importFailures.map(\.url), [second])
        model.sheet = nil; model.sheetDidDismiss()
        XCTAssertTrue(model.importFailures.isEmpty)
        model.sheetDidDismiss()
        XCTAssertTrue(model.importFailures.isEmpty, "Dismissal cleanup is safe to repeat")
    }

    @MainActor func testOlderSheetDismissalDoesNotClearNewImportResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
                                    libraryDirectory: directory.appendingPathComponent("books"))
        try await service.prepareLibrary()
        let model = LibraryModel(service: service)
        let missing = directory.appendingPathComponent("missing.txt")
        model.runAfterSheetDismiss { model.receive([missing]) }
        model.sheetDidDismiss()
        try await waitForLibraryState { model.sheet?.id == "import-results" }
        model.sheetDidDismiss()
        XCTAssertEqual(model.importFailures.map(\.url), [missing], "A late callback must not clear the new results sheet")
        model.sheet = nil; model.sheetDidDismiss()
        XCTAssertTrue(model.importFailures.isEmpty)
    }

    func testChapterListCaptionHidesOnlyRecordedZeroCoverage() {
        func entry(_ count: UInt64, complete: Bool = true, covered: UInt64?) -> ChapterEntry {
            ChapterEntry(startUtf8: 0, title: "第 1 章", wordCount: count, countComplete: complete, level: 1,
                         parentUtf8: nil, parentTitle: nil, coveredCharacters: covered)
        }
        XCTAssertNil(entry(1000, covered: 0).listCoverageLabel, "A fully counted chapter with nothing recorded shows only its count")
        XCTAssertEqual(entry(1000, covered: 400).listCoverageLabel, entry(1000, covered: 400).coverageLabel)
        XCTAssertEqual(entry(1000, covered: 5).listCoverageLabel, "已读不足 1%")
        XCTAssertEqual(entry(1000, covered: nil).listCoverageLabel, "—", "Unknown coverage stays visible")
        XCTAssertEqual(entry(1000, complete: false, covered: 0).listCoverageLabel, "—", "An incomplete count is not a recorded zero")
        XCTAssertEqual(entry(0, covered: 0).listCoverageLabel, "—")
    }

    @MainActor func testPullDuringRefreshWaitsForSharedWorkAndRunsAnotherPass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
                                    libraryDirectory: directory.appendingPathComponent("books"))
        let entered = expectation(description: "Automatic refresh started")
        let probe = LibraryRefreshProbe(gate: SourceReadinessGate(entered: entered))
        let model = LibraryModel(service: service, refreshLibrary: { await probe.refresh() })
        let loaded = await model.load()
        XCTAssertTrue(loaded)
        // Initialization starts an automatic refresh; a pull arrives while it runs.
        await fulfillment(of: [entered], timeout: 2)
        let pull = Task { await model.refresh(showIndicator: false, userInitiated: true) }
        await awaitState { model.nativeRefreshing }
        XCTAssertTrue(model.nativeRefreshing, "The pull's spinner stays while the shared refresh runs")
        await probe.gate.release()
        await pull.value
        let passes = await probe.passes
        XCTAssertEqual(passes, 2, "Joining asks for one more pass so the pull sees current files")
        XCTAssertFalse(model.nativeRefreshing)
    }

    @MainActor private func waitForLibraryState(file: StaticString = #filePath, line: UInt = #line,
                                                _ condition: @escaping @MainActor () -> Bool) async throws {
        await awaitState(condition)
        XCTAssertTrue(condition(), "Library state did not settle", file: file, line: line)
    }

    @MainActor func testLibraryInitializationRetriesAndConcurrentCallersWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
                                    libraryDirectory: directory.appendingPathComponent("books"))
        let entered = expectation(description: "Retry is preparing")
        let gate = SourceReadinessGate(entered: entered)
        let probe = LibraryInitializationProbe(gate: gate)
        let model = LibraryModel(service: service, prepareLibrary: { try await probe.prepare(service) })
        let failed = await model.load()
        XCTAssertFalse(failed)
        XCTAssertNotNil(model.error)
        let first = Task { await model.load() }
        await fulfillment(of: [entered], timeout: 2)
        var secondFinished = false
        let second = Task { let ready = await model.load(); secondFinished = true; return ready }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(secondFinished, "Open URL must await initialization, not proceed into an unregistered shelf")
        first.cancel()
        await gate.release()
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult, "Cancelling a view must not cancel shared model initialization")
        XCTAssertNil(model.error)
        XCTAssertTrue(model.shelves.contains { $0.builtin })
        let readyAgain = await model.load(), attempts = await probe.attempts
        XCTAssertTrue(readyAgain)
        XCTAssertEqual(attempts, 2)
    }

    func testExportStagingFollowsOwnershipAndCleansPartialFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("books")
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path), libraryDirectory: root)
        try await service.prepareLibrary()
        try await service.refreshLibrary()
        let entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
        let original = root.appendingPathComponent(entry.name)
        let originalBytes = try Data(contentsOf: original)
        var presentation: LibraryExport? = try await service.exportLibraryFiles([entry])
        let stagedDirectory = try XCTUnwrap(presentation?.directory)
        let stagedURL = try XCTUnwrap(presentation?.urls.first)
        XCTAssertEqual(try Data(contentsOf: stagedURL), originalBytes)
        var activity = presentation
        presentation = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path), "A still-running system activity owns its input")
        withExtendedLifetime(activity) {}
        activity = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)

        var failedDirectory: URL?
        XCTAssertThrowsError(try LibraryExport { staging in
            failedDirectory = staging
            try originalBytes.write(to: staging.appendingPathComponent("copied.txt"))
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(failedDirectory).path))
    }

    func testRestartedImportPreservesPreferredFileAmongIdenticalCopies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Moonread-RestartSource-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let root = directory.appendingPathComponent("books")
        for folder in ["a", "b"] {
            let parent = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try "Chapter 1\nThe same story in two folders.\n".write(to: parent.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
        }
        let core = try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite)
        try await service.prepareLibrary()
        try await service.refreshLibrary()
        let entries = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
        let first = try XCTUnwrap(entries.first { $0.relativePath == "a/story.txt" })
        let second = try XCTUnwrap(entries.first { $0.relativePath == "b/story.txt" })
        func waitForComplete(_ id: String) async throws {
            try await service.waitForImportFinish(id)
            XCTFail("Import did not complete")
        }
        let firstLease = try await service.openSourceFile(first.source)
        try await waitForComplete(firstLease.id)
        try await service.savePosition(bookID: firstLease.id, offset: 10)
        let secondLease = try await service.openSourceFile(second.source)
        try await waitForComplete(secondLease.id)
        // Restart uses the same descriptor path for failed, paused and completed tasks.
        // Keep leases alive so the descriptor remains available for this explicit restart.
        let restarted = try await service.restartImport(secondLease.id, encoding: "gb18030")
        try await waitForComplete(restarted.id)
        try await service.savePosition(bookID: restarted.id, offset: 20)
        let snapshot = try await service.snapshot(restarted.id)
        XCTAssertEqual(defaults.string(forKey: "Moonread.preferredFile." + snapshot.book.contentSha256), second.id)
        let recent = try await service.recentLibrary()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, second.id)
        let reopened = try await service.openSourceFile(try XCTUnwrap(recent.first).source)
        try await waitForComplete(reopened.id)
        let reopenedSnapshot = try await service.snapshot(reopened.id)
        XCTAssertEqual(reopenedSnapshot.book.positionUtf8, snapshot.book.positionUtf8)
        withExtendedLifetime((firstLease, secondLease, restarted, reopened)) {}
    }

    func testRepeatedOpeningReclaimsTasksAndBookmarksButKeepsReadingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Moonread-LifetimeTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let core = try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: directory.appendingPathComponent("books"), sourceDefaultsSuite: suite)
        try await service.prepareLibrary()
        try await service.refreshLibrary()
        let entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
        var canonical: String?
        var position: UInt64 = 0
        for index in 0..<6 {
            var lease: ReadingLease? = try await service.openSourceFile(entry.source)
            let id = try XCTUnwrap(lease?.id)
            try await service.waitForImportFinish(id)
            let snapshot = try await service.snapshot(id)
            XCTAssertEqual(snapshot.phase, .complete)
            if index == 0 {
                canonical = id
                try await service.savePosition(bookID: id, offset: 90)
                position = try await service.snapshot(id).book.positionUtf8
                _ = try await service.toggleBookmark(id, at: position)
            } else {
                XCTAssertEqual(snapshot.book.positionUtf8, position)
                let bookmarked = try await service.hasBookmark(id, at: position)
                XCTAssertTrue(bookmarked)
            }
            XCTAssertNotNil(defaults.data(forKey: "Moonread.importSource.library.\(id)"))
            withExtendedLifetime(lease) {}
            lease = nil
            try await service.waitForReadingIdle()
            XCTAssertNil(defaults.data(forKey: "Moonread.importSource.library.\(id)"))
            XCTAssertNil(defaults.string(forKey: "Moonread.sourceDraft.library.\(entry.id)"))
            XCTAssertTrue(try core.reclaimCompletedImports(retainedBookIds: []).isEmpty)
            XCTAssertEqual(try core.querySnapshot(json: "{}").recentReadings().count, 1)
            XCTAssertEqual(try core.querySnapshot(json: "{}").libraryEntry(fileId: entry.id).bookId, canonical)
            let bookmarkedCanonical = try await service.hasBookmark(try XCTUnwrap(canonical), at: position)
            XCTAssertTrue(bookmarkedCanonical)
            if index > 0 { XCTAssertThrowsError(try core.querySnapshot(json: "{}").readingSnapshot(bookId: id)) }
        }
        // Simulate termination after the DB transaction, before defaults cleanup.
        defaults.set(Data([1]), forKey: "Moonread.importSource.library.orphan")
        defaults.set("orphan", forKey: "Moonread.sourceDraft.library.orphan-file")
        let restarted = ReaderService(core: core, sourceDefaultsSuite: suite)
        _ = try await restarted.book(try XCTUnwrap(canonical))
        await restarted.startUserRecovery()
        await restarted.waitForUserRecovery()
        XCTAssertNil(defaults.data(forKey: "Moonread.importSource.library.orphan"))
        XCTAssertNil(defaults.string(forKey: "Moonread.sourceDraft.library.orphan-file"))
    }

    @MainActor func testNativeLibrarySelectionBindings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = directory.appendingPathComponent("books")
        let service = ReaderService(core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path), libraryDirectory: books)
        try await service.prepareLibrary()
        try "第一章\n月光下的故事。".write(to: books.appendingPathComponent("第二本名字很长很长但在列表中仍然只显示一行的小说.txt"), atomically: true, encoding: .utf8)
        try await service.refreshLibrary()
        let location = LibraryLocation(shelfID: "builtin")
        let entries = try await service.libraryEntries(location)
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        var editing = EditMode.inactive
        var selection = Set<String>()
        let model = LibraryModel()
        let suite = "LibrarySelectionHost-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ai = AIService(defaults: defaults, storefront: .fixed("USA"), reader: service)
        func config(_ layout: LibraryLayout = .grid, disabled: Bool = false) -> LibraryCollection {
            LibraryCollection(ai: ai, model: model, location: location, entries: entries, shelf: nil, layout: layout, theme: .initial,
                              disabled: disabled, editing: Binding(get: { editing }, set: { editing = $0 }),
                              selection: Binding(get: { selection }, set: { selection = $0 }))
        }
        let controller = LibraryCollection.Controller()
        controller.update(config())
        let native = try XCTUnwrap(controller.collectionView)
        let first = IndexPath(item: 0, section: 1), second = IndexPath(item: 1, section: 1)
        XCTAssertTrue(native.allowsMultipleSelectionDuringEditing)
        XCTAssertFalse(controller.collectionView(native, shouldBeginMultipleSelectionInteractionAt: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(controller.collectionView(native, shouldBeginMultipleSelectionInteractionAt: first))
        controller.collectionView(native, didBeginMultipleSelectionInteractionAt: first)
        controller.update(config())
        XCTAssertTrue(editing.isEditing); XCTAssertTrue(native.isEditing)
        for path in [first, second] {
            native.selectItem(at: path, animated: false, scrollPosition: [])
            controller.collectionView(native, didSelectItemAt: path)
        }
        XCTAssertEqual(selection, Set(entries.prefix(2).map(\.id)))
        native.deselectItem(at: first, animated: false)
        controller.collectionView(native, didDeselectItemAt: first)
        XCTAssertEqual(selection, [entries[1].id])
        controller.update(config(.list))
        XCTAssertEqual(selection, [entries[1].id], "Changing layout preserves the application binding")
        controller.update(config(.list, disabled: true))
        XCTAssertFalse(controller.collectionView(native, shouldBeginMultipleSelectionInteractionAt: first))
        editing = .inactive; selection = []; controller.update(config(.list))
        XCTAssertTrue(native.indexPathsForSelectedItems?.isEmpty ?? true)
    }

    func testCoverIsOutsideTextCoordinatesAcrossWindowAndLayoutChanges() throws {
        let window = ReadingWindow(chunks: Array(readingChunks().prefix(2)))
        let body = ReadingText(window), covered = body.prefixed("\u{fffc}\n")
        XCTAssertNil(covered.coordinates.sourcePoint(0)); XCTAssertNil(covered.coordinates.sourcePoint(1))
        XCTAssertEqual(covered.coordinates.sourcePoint(2), body.coordinates.sourcePoint(0))
        let source = try XCTUnwrap(covered.coordinates.sourceRange(covered.selectableRange))
        XCTAssertEqual(UInt64(source.lowerBound) + covered.sourceStart, window.start)
        XCTAssertEqual(UInt64(source.upperBound) + covered.sourceStart, window.end)
        XCTAssertEqual(covered.slice(covered.selectableRange).text, body.text)
        let extended = ReadingText(ReadingWindow(chunks: Array(readingChunks().prefix(3)))).prefixed("\u{fffc}\n")
        XCTAssertEqual(extended.coordinates.sourcePoint(2), 0)
    }

    @MainActor func testCoverPreservesReadingIdentityAndResume() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let source = temporary.appendingPathComponent("原文.txt")
        let original = "第一章 月光\n\n" + String(repeating: "月光下的故事继续展开。\n", count: 100)
        try original.write(to: source, atomically: true, encoding: .utf8)
        let book = try core.importBook(filePath: source.path, title: "月光下的归途")
        let service = ReaderService(core: core)
        let session = ReaderSession(service: service)
        await session.open(.book(book.id))
        await awaitState { session.window != nil }
        XCTAssertNotNil(session.window); XCTAssertTrue(session.showingCover)
        await session.flush()
        XCTAssertFalse(try core.querySnapshot(json: "{}").readingSnapshot(bookId: book.id).hasStarted)
        let bookmarked = await session.toggleBookmark()
        XCTAssertFalse(bookmarked)
        session.moved(to: 0, settled: true); await session.flush()
        let startedSnapshot = try await service.snapshot(book.id)
        XCTAssertTrue(startedSnapshot.hasStarted, "Body offset zero differs from the cover")
        session.moved(to: UInt64("第一章 月光\n\n月光下的故事继续展开。\n".utf8.count), settled: true); await session.flush()
        let position = try await service.snapshot(book.id).book.positionUtf8
        session.browse(to: 0, placement: .cover)
        await awaitState { !session.navigating }
        XCTAssertTrue(session.showingCover); await session.flush()
        let retainedPosition = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(retainedPosition, position)
        await session.returnFromBrowse()
        XCTAssertFalse(session.showingCover); XCTAssertEqual(session.anchor, position)
        await session.leave().value
        let resumed = ReaderSession(service: service)
        await resumed.open(.book(book.id))
        await awaitState { resumed.window != nil }
        XCTAssertFalse(resumed.showingCover); XCTAssertEqual(resumed.anchor, position)
        await resumed.leave().value
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
        XCTAssertEqual(try core.querySnapshot(json: "{}").bookInfo(bookId: book.id).contentSha256, book.contentSha256)
    }

    @MainActor func testOpeningWaitsForSourceAndCancellationCannotNavigate() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path), libraryDirectory: temporary.appendingPathComponent("books"))
        try await service.prepareLibrary(); try await service.refreshLibrary()
        var entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
        entry.needsDownload = true
        let entered = expectation(description: "source requested")
        let finished = expectation(description: "cancelled source finished")
        let gate = SourceReadinessGate(entered: entered)
        let model = LibraryModel(prepareSource: { _, report in
            report(0.25); await gate.wait(); report(0.9); finished.fulfill()
        })
        model.open(entry)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.path.isEmpty, "Downloading must stay on the shelf")
        XCTAssertEqual(model.openingFileID, entry.id)
        XCTAssertTrue(model.showsFileLoading, "A known download must show feedback immediately")
        XCTAssertEqual(model.fileProgress, 0.25)
        model.cancelOpening()
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertNil(model.openingFileID)
        XCTAssertNil(model.fileProgress, "Cancelled progress must not return from a late callback")
        XCTAssertTrue(model.path.isEmpty)

        let ready = expectation(description: "next source requested")
        let nextGate = SourceReadinessGate(entered: ready)
        let next = LibraryModel(prepareSource: { _, _ in await nextGate.wait() })
        next.open(entry)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(next.path.isEmpty)
        await nextGate.release()
        await awaitState { !next.path.isEmpty }
        guard case let .reader(opening) = next.path.first else { return XCTFail("Missing reader opening") }; XCTAssertEqual(opening.target, .source(entry.source))
    }

    @MainActor func testLoadingStateRejectsSupersededCompletionAndDownloadUnits() {
        let loading = LoadingState()
        let old = loading.begin(), current = loading.begin()
        loading.finish(old)
        XCTAssertEqual(loading.request, current)
        loading.finish(current)
        XCTAssertFalse(loading.active)
        XCTAssertEqual(SourceDownloadProgress.fraction(percent: 25), 0.25)
        XCTAssertEqual(SourceDownloadProgress.fraction(percent: 100), 1)
        XCTAssertEqual(SourceDownloadProgress.fraction(percent: 0), 0)
        XCTAssertNil(SourceDownloadProgress.fraction(percent: nil))
        XCTAssertNil(SourceDownloadProgress.fraction(percent: NSNumber(value: Double.nan)))
        XCTAssertNil(SourceDownloadProgress.fraction(percent: 101))
    }

    func testSourceAvailabilityDoesNotImportOrRecordReading() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let root = temporary.appendingPathComponent("books")
        let service = ReaderService(core: core, libraryDirectory: root)
        try await service.prepareLibrary()
        try await service.refreshLibrary()
        let entries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
        try await service.prepareSourceFile(entries[0].source)
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
        XCTAssertTrue(try core.querySnapshot(json: "{}").recentLibraryEntries(limit: 3).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(entries[0].name))
        do {
            try await service.prepareSourceFile(entries[0].source)
            XCTFail("Missing originals must fail on the shelf before opening a reader")
        } catch { }
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
    }

    func testCancelledSourceAccessNeverStartsProcessing() async throws {
        let access = SourceFileAccess(bookmark: Data(), path: "unused.txt")
        access.cancel()
        do { try await access.prepare(); XCTFail("Cancelled access must stop before resolving the bookmark") }
        catch is CancellationError { }
    }

    func testLibraryAlphabetUsesPinyinAndNaturalNumberOrder() throws {
        XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("《晨光》")), "C")
        XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("夜航")), "Y")
        XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("étoile")), "E")
        XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("123")), "#")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let core = try ReaderCore(dataDirectory: temporary.path)
        try core.saveLibraryShelf(id: "builtin", name: "test", bookmark: Data([1]), location: "local", builtin: true)
        try core.scanLibraryShelf(shelfId: "builtin", items: ["夜航.txt", "山海10.txt", "山海2.txt", "晨光.txt", "1.txt"].map {
            ScannedLibraryItem(relativePath: $0, directory: false, size: 10, modified: 1, needsDownload: false)
        })
        let entries = try core.querySnapshot(json: "{}").libraryEntries(shelfId: "builtin", parentPath: "", sort: .name)
        let groups = LibraryNameGroup.group(entries)
        XCTAssertEqual(groups.map(\.id), ["C", "S", "Y", "#"])
        XCTAssertEqual(groups[1].entries.map(\.title), ["山海2", "山海10"])
    }

    func testWelcomeBookIsARealFileSeededOnlyOnce() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = temporary.appendingPathComponent("db")
        let root = temporary.appendingPathComponent("books")
        let core = try ReaderCore(dataDirectory: data.path)
        let service = ReaderService(core: core, libraryDirectory: root, libraryDeletion: { url, _ in try TrashIOProbe.move(url) })
        try await service.prepareLibrary()
        try await service.refreshLibrary()
        let entries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
        XCTAssertEqual(entries.map(\.name), ["月光下的归途.txt"])
        XCTAssertTrue(try core.querySnapshot(json: "{}").recentLibraryEntries(limit: 3).isEmpty)
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil }, "Creating the file must not import it or mark it as read")
        let file = root.appendingPathComponent(entries[0].name)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("第三章 灯下"))
        try await service.deleteLibraryItem(entries[0])
        let reopened = ReaderService(core: try ReaderCore(dataDirectory: data.path), libraryDirectory: root)
        try await reopened.prepareLibrary()
        try await reopened.refreshLibrary()
        let remaining = try await reopened.libraryEntries(LibraryLocation(shelfID: "builtin"))
        XCTAssertTrue(remaining.isEmpty, "Deleting the welcome book must survive reinitialization")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLibraryScanResolvesRootAliasesBeforeComputingRelativePaths() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let actualParent = temporary.appendingPathComponent("actual-location")
        let actual = actualParent.appendingPathComponent("Documents")
        let nested = actual.appendingPathComponent("卷一")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = temporary.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: actualParent)
        let text = "第一章 月光\n正文。\n第二章 灯下\n另一段正文。\n"
        try text.write(to: actual.appendingPathComponent("测试.txt"), atomically: true, encoding: .utf8)
        try text.write(to: nested.appendingPathComponent("嵌套.txt"), atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: alias.appendingPathComponent("Documents"))
        try await service.prepareLibrary()
        try await service.scanLibraryShelf("builtin")
        let entries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["测试.txt", "卷一"])
        let books = try await service.allLibraryBooks("builtin")
        XCTAssertEqual(Set(books.map(\.relativePath)), ["测试.txt", "卷一/嵌套.txt"])
        for book in books {
            let staged = try await service.exportLibraryFiles([book])
            defer { staged.finish() }
            XCTAssertEqual(try String(contentsOf: staged.urls[0], encoding: .utf8), text)
        }
    }

    func testLibraryFilesKeepContentRecordsAcrossRenameMoveAndDeletion() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let root = temporary.appendingPathComponent("我的书架")
        let external = temporary.appendingPathComponent("外部")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let service = ReaderService(core: core, libraryDirectory: root, libraryDeletion: { url, _ in try TrashIOProbe.move(url) })
        try await service.prepareLibrary()
        let original = temporary.appendingPathComponent("山海.txt")
        let text = "第一章 月光\n\n" + String(repeating: "这是一段只用于测试的文字。\n", count: 200)
        try text.write(to: original, atomically: true, encoding: .utf8)
        let received = try await service.receiveLibraryFile(original, at: LibraryLocation(shelfID: "builtin"), replace: false)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), text)
        let lease = try await service.openSourceFile(received.source)
        let id = lease.id
        defer { withExtendedLifetime(lease) {} }
        try await service.waitForImportFinish(id)
        let book = try await service.snapshot(id).book
        let completed = try await service.snapshot(id)
        XCTAssertEqual(completed.phase, .complete)
        try await service.savePosition(bookID: id, offset: 9)
        _ = try await service.toggleBookmark(book.id, at: 9)
        try await service.renameLibraryItem(received, name: "新名.txt", replace: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("山海.txt").path))
        let renamed = try core.querySnapshot(json: "{}").libraryEntry(fileId: received.id)
        XCTAssertEqual(renamed.bookId, book.id)
        let externalID = try await service.registerLibraryShelf(external)
        try await service.scanLibraryShelf(externalID)
        try await service.moveLibraryItem(renamed, to: LibraryLocation(shelfID: externalID), replace: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("新名.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("新名.txt").path))
        let moved = try await service.libraryEntry(received.id)
        XCTAssertEqual(moved.shelfId, externalID)
        XCTAssertEqual(moved.positionUtf8, 9)
        let bookmarked = try await service.hasBookmark(book.id, at: 9)
        XCTAssertTrue(bookmarked)
        try await service.deleteLibraryItem(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("新名.txt").path))
        let retainedBookmark = try await service.hasBookmark(book.id, at: 9)
        XCTAssertTrue(retainedBookmark)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testLibraryImportConflictPreservesOriginalUntilReplacement() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let root = temporary.appendingPathComponent("books")
        let service = ReaderService(core: core, libraryDirectory: root)
        try await service.prepareLibrary()
        let source = temporary.appendingPathComponent("同名.txt")
        try "旧原文".write(to: source, atomically: true, encoding: .utf8)
        _ = try await service.receiveLibraryFile(source, at: LibraryLocation(shelfID: "builtin"), replace: false)
        try "新原文".write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await service.receiveLibraryFile(source, at: LibraryLocation(shelfID: "builtin"), replace: false)
            XCTFail("Same-name import requires a choice")
        } catch LibraryFileError.conflict { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("同名.txt"), encoding: .utf8), "旧原文")
        _ = try await service.receiveLibraryFile(source, at: LibraryLocation(shelfID: "builtin"), replace: true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("同名.txt"), encoding: .utf8), "新原文")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "新原文")
    }

    @MainActor
    func testNavigationCancellationWaitsForSheetDismissalInEitherOrder() {
        for dismissFirst in [true, false] {
            let state = NavigationPresentationState()
            state.begin(hasPresentation: true)
            if dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
            state.finish(cancelled: true)
            XCTAssertEqual(state.isSuspended, !dismissFirst)
            if !dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
            XCTAssertFalse(state.isSuspended)
            XCTAssertFalse(state.presentationDismissed(), "Only the navigation dismissal is consumed")
        }
        let state = NavigationPresentationState()
        state.begin(hasPresentation: false)
        state.finish(cancelled: true)
        XCTAssertFalse(state.isSuspended)
    }

    @MainActor
    func testCompletedNavigationDoesNotReopenSheetFromLateDismissal() {
        let state = NavigationPresentationState()
        state.begin(hasPresentation: true)
        state.finish(cancelled: false)
        XCTAssertTrue(state.presentationDismissed())
        XCTAssertTrue(state.isSuspended)
        state.appear()
        XCTAssertFalse(state.isSuspended, "Returning from a child settings page can restore its preview")
    }

    @MainActor
    func testPreviewRestoresExactOffsetAfterNavigationCancellation() throws {
        let source = ReadingPreviewSource.sample
        let settings = defaultReaderSettings()
        let surface = ThemeSurface.initial
        let first = ReadingPreviewTextView()
        first.frame = CGRect(x: 0, y: 0, width: 370, height: 260)
        first.configure(source: source, settings: settings, surface: surface, typeSize: .large)
        first.layoutIfNeeded()
        first.setContentOffset(CGPoint(x: 0, y: 123), animated: false)
        let position = first.capturePosition()
        let restored = ReadingPreviewTextView()
        restored.frame = first.frame
        restored.configure(source: source, settings: settings, surface: surface, typeSize: .large, restored: position)
        restored.layoutIfNeeded()
        XCTAssertEqual(restored.contentOffset.y, first.contentOffset.y, accuracy: 0.5)
        XCTAssertEqual(restored.capturePosition().anchor, position.anchor)
    }

    @MainActor
    func testLivePreviewSharesTypographyAndOnlyRepaintsForColors() throws {
        let source = ReadingPreviewSource.sample
        let view = ReadingPreviewTextView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 280)
        var settings = defaultReaderSettings()
        let snapshot = defaultThemeSnapshot()
        let light = ThemeSurface(plan: try resolveThemes(value: snapshot, system: .light, highContrast: false).reader)
        let dark = ThemeSurface(plan: try resolveThemes(value: snapshot, system: .dark, highContrast: false).reader)
        view.configure(source: source, settings: settings, surface: light, typeSize: .large)
        view.layoutIfNeeded()
        XCTAssertEqual(view.text, ReadingText(source.window).text)
        XCTAssertEqual(view.textContainerInset.left, 16)
        settings.fontSize = 28; settings.horizontalMargin = 24; settings.lineSpacing = 12
        view.configure(source: source, settings: settings, surface: light, typeSize: .large)
        view.layoutIfNeeded()
        let expected = ReadingTypography.text(source.window, settings: settings, ink: light.ink)
        let firstBody = (ReadingText(source.window).text as NSString).range(of: "\n").upperBound
        XCTAssertEqual((view.textStorage.attribute(.font, at: firstBody, effectiveRange: nil) as? UIFont)?.pointSize,
                       (expected.attribute(.font, at: firstBody, effectiveRange: nil) as? UIFont)?.pointSize)
        XCTAssertEqual(view.textContainerInset.left, 24)
        view.setContentOffset(CGPoint(x: 0, y: 96), animated: false)
        let before = view.contentOffset
        let original = NSAttributedString(attributedString: view.textStorage)
        view.configure(source: source, settings: settings, surface: dark, typeSize: .large)
        view.layoutIfNeeded()
        XCTAssertTrue(view.textStorage.isEqual(to: original), "Preview color changes should not edit text storage")
        XCTAssertEqual(view.contentOffset, before)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isSelectable)
        let manager = try XCTUnwrap(view.layoutManager as? ReadingLayoutManager)
        XCTAssertEqual(manager.decorations.count, 2)
        XCTAssertEqual(manager.decorations.first?.color, dark.annotation)
    }



    func testReaderDeviceControlsReleaseAwakeAndOrientationOnBackgroundAndExit() {
        var awake = [Bool](), orientation = [ReadingOrientation?]()
        let controls = ReaderDeviceControls(effects: .init(awake: { awake.append($0) }, orientation: { orientation.append($0) }))
        var settings = defaultReaderSettings(); settings.keepAwake = true; settings.orientation = .portrait
        controls.update(settings); XCTAssertTrue(awake.isEmpty)
        controls.sceneActive(true); XCTAssertEqual(awake, [true]); XCTAssertEqual(orientation.last!, .portrait)
        controls.sceneActive(false); XCTAssertEqual(awake, [true, false]); XCTAssertNil(orientation.last!)
        controls.sceneActive(true); controls.stop(); XCTAssertEqual(awake, [true, false, true, false])
        XCTAssertNil(orientation.last!)
    }

    @MainActor
    func testLeavingReaderFreezesProgressAndRejectsLatePresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try ReaderCore(dataDirectory: directory.path)
        let book = try core.createSampleBook()
        let service = ReaderService(core: core)
        let session = ReaderSession(service: service)
        await session.open(.book(book.id))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
        await fulfillment(of: [loaded], timeout: 5)
        let projection = try XCTUnwrap(session.window.map { ReadingText($0) })
        let original = projection.sourceStart + UInt64(try XCTUnwrap(projection.coordinates.sourcePoint(projection.text.prefix(30).utf16.count)))
        let preview = projection.sourceStart + UInt64(try XCTUnwrap(projection.coordinates.sourcePoint(projection.text.prefix(300).utf16.count)))
        // Enter the body before simulating a temporary preview; the cover is unread.
        session.moved(to: original, settled: true)
        XCTAssertFalse(session.showingCover)
        session.anchor = preview
        session.browseOrigin = original
        session.selectionStart = original
        let mark = try await service.annotate(book.id, start: 0, end: original)
        // This task has been requested but has not returned its editor yet.
        session.openAnnotation(mark.id)
        let saved = session.leave()
        XCTAssertTrue(session.isLeaving)
        session.clearTransientState()
        XCTAssertNil(session.browseOrigin)
        XCTAssertNil(session.selectionStart)
        session.moved(to: preview + 3, settled: true)
        session.browse(to: original + 3)
        session.selectText(start: 0, end: original, action: .beginRange)
        XCTAssertEqual(session.anchor, preview)
        await saved.value
        // A later background/disappearance flush must use the same frozen origin.
        await session.flush()
        XCTAssertNil(session.editor)
        XCTAssertNil(session.selectionStart)
        XCTAssertNil(session.browseOrigin)
        XCTAssertNil(session.error)
        let finalPosition = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(finalPosition, original)
    }

    func testNavigationPlacesContextKeepsVisibleHitsAndRestoresExactScrollViewport() throws {
        let settings = defaultReaderSettings(), size = CGSize(width: 390, height: 650)
        let saved = ReadingViewport(offset: 30, lineY: -4, size: size, settings: settings, typeSize: .large, pages: [])
        let restore = ReadingNavigation(restoring: saved)
        XCTAssertEqual(restore.restoration(size: size, settings: settings, typeSize: .large)?.offset, 30)
        XCTAssertNil(restore.restoration(size: .zero, settings: settings, typeSize: .large))
        XCTAssertEqual(restore.scrollTarget(lineY: 100, textInset: 16, target: .zero, visible: .zero, keepVisible: false), 120)
        let context = ReadingNavigation(placement: .context, bottomObstruction: 124)
        let visible = CGRect(x: 0, y: 100, width: 390, height: 300)
        XCTAssertNil(context.scrollTarget(lineY: 120, textInset: 16, target: CGRect(x: 0, y: 120, width: 20, height: 20), visible: visible, keepVisible: true))
        XCTAssertEqual(context.scrollTarget(lineY: 500, textInset: 16, target: CGRect(x: 0, y: 500, width: 20, height: 20), visible: visible, keepVisible: true), 384)
        XCTAssertEqual(ReadingNavigation().scrollTarget(lineY: 500, textInset: 16, target: .zero, visible: .zero, keepVisible: false), 500)
    }

    func testNavigationPreservesPageBoundariesAndReturnsAfterDistantJump() throws {
        let chunks = readingChunks(), window = ReadingWindow(chunks: Array(chunks.prefix(3)))
        let pages = syntheticPages(window), saved = pages[3]
        let request = ReadingNavigation(placement: .context)
        XCTAssertEqual(request.pageIndex(in: pages, anchor: saved.start + 3), 3)
        XCTAssertEqual(request.pageIndex(in: pages, anchor: saved.end - 1), 3)
        let restore = ReadingViewport(offset: saved.start, lineY: 0, size: .zero, settings: defaultReaderSettings(), typeSize: .large, pages: pages)
        let returned = syntheticPages(window, preserving: restore.pages, keeping: restore.offset)
        XCTAssertEqual(returned.map(\.start), pages.map(\.start))
        XCTAssertEqual(request.pageIndex(in: returned, anchor: restore.offset), 3)
    }

    @MainActor
    private func findReadingText(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.findReadingText(in: $0) }.first
    }

    @MainActor
    func testThemePreferencesStayInteractiveAndCoalescePendingWrites() async {
        let writer = ThemePreferenceWriterProbe()
        let store = ThemeStore(persistPreferences: writer.save)
        writer.snapshot = store.snapshot
        let firstWrite = expectation(description: "First preference write started")
        let nextWrite = expectation(description: "Newest preference write started")
        writer.started = { count in
            if count == 1 { firstWrite.fulfill() }
            if count == 2 { nextWrite.fulfill() }
        }

        store.update { $0.appMode = $0.appMode == .dark ? .light : .dark }
        let first = store.snapshot.preferences
        await fulfillment(of: [firstWrite], timeout: 2)
        XCTAssertFalse(store.saving, "A background preference write must not dim or disable controls")
        store.update { $0.appMode = first.appMode == .dark ? .light : .dark }
        store.update { $0.reduceMotion.toggle() }
        let latest = store.snapshot.preferences
        XCTAssertNotEqual(latest, first)
        XCTAssertEqual(writer.requests.count, 1, "Writes must remain serialized")

        writer.succeed()
        await fulfillment(of: [nextWrite], timeout: 2)
        XCTAssertEqual(store.snapshot.preferences, latest, "An older response must not flash the old theme")
        XCTAssertEqual(writer.requests.last, latest, "Rapid edits must retain all latest fields")
        writer.succeed()
        await store.flushPreferences()
        XCTAssertEqual(store.snapshot.preferences, latest)
        store.update { $0 = latest }
        await store.flushPreferences()
        XCTAssertEqual(writer.requests.count, 2, "An unchanged preference does not need another write")
    }

    @MainActor
    func testThemePreferenceFailureRollsBackToLastSavedEdit() async {
        let writer = ThemePreferenceWriterProbe()
        let store = ThemeStore(persistPreferences: writer.save)
        writer.snapshot = store.snapshot
        let firstWrite = expectation(description: "First write")
        let nextWrite = expectation(description: "Queued write")
        writer.started = { count in
            if count == 1 { firstWrite.fulfill() }
            if count == 2 { nextWrite.fulfill() }
        }
        store.update { $0.reduceMotion.toggle() }
        let saved = store.snapshot.preferences
        await fulfillment(of: [firstWrite], timeout: 2)
        store.update { $0.readerMode = $0.readerMode == .dark ? .light : .dark }
        let newer = store.snapshot.preferences
        writer.succeed()
        await fulfillment(of: [nextWrite], timeout: 2)
        XCTAssertEqual(store.snapshot.preferences, newer)
        writer.fail()
        await store.flushPreferences()
        XCTAssertEqual(store.snapshot.preferences, saved)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.saving)
    }

    func testRawSHADetectsSameLengthEditWithPreservedModificationDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("revision.txt")
        try Data("第一章 起点\n正文甲".utf8).write(to: url)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let service = ReaderService()
        let initialValue = try CloudDocumentHandoff.bytesHash(url)
        let initial = try XCTUnwrap(initialValue)
        let unchanged = try CloudDocumentHandoff.bytesHash(url)
        XCTAssertEqual(initial, unchanged, "Unchanged local files must be reusable")

        try Data("第一章 起点\n正文乙".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let changedValue = try CloudDocumentHandoff.bytesHash(url)
        let changed = try XCTUnwrap(changedValue)
        XCTAssertNotEqual(initial, changed,
                          "Preserving size and modification time must not reuse stale text")
    }

    @MainActor
    func testScrollFadeDistinguishesLoadedWindowEdgeFromBookEnd() {
        // Exhausting a temporary chunk window must not masquerade as the end
        // of a novel; only the real final line should remove the edge fade.
        XCTAssertEqual(ReadingTextMetrics.fadeOpacity(remaining: 0, isEndOfBook: false), 1)
        XCTAssertEqual(ReadingTextMetrics.fadeOpacity(remaining: 0, isEndOfBook: true), 0)
        XCTAssertEqual(ReadingTextMetrics.fadeOpacity(remaining: 200, isEndOfBook: true), 1)
        XCTAssertEqual(ReadingTextMetrics.fadeOpacity(remaining: 0, isEndOfBook: false, isPreparedTail: true), 0,
                       "The last committed line must remain readable while import is paused or preparing")
    }




    func testHighlightChangesNeverEditTextOrMoveSelectionAndViewport() {
        let layout = ReadingLayoutManager()
        var commands = [NSRange]()
        layout.invalidatePaint = { commands.append($0) }
        let mark = ReadingLayoutManager.Decoration(range: NSRange(location: 2, length: 3), color: .systemPink)
        layout.setDecorations([mark]); layout.setDecorations([mark])
        XCTAssertEqual(layout.decorations, [mark]); XCTAssertEqual(commands.count, 1)
        layout.setDecorations([]); XCTAssertTrue(layout.decorations.isEmpty); XCTAssertEqual(commands.count, 2)
        XCTAssertNil(layout.textStorage, "Paint commands require neither text replacement nor a native selection/viewport")
    }

    func testUTF8AndUTF16RoundTripAtEveryScalarBoundary() {
        let text = "月亮🌙，👨‍👩‍👧‍👦与e\u{301}，𠮷。\n下一行"
        for prefix in [0, 2] {
            let mapping = TextCoordinates(text, leadingUTF16: prefix)
            var bytes = 0
            var units = prefix
            XCTAssertEqual(mapping.utf16Offset(atUTF8: 0), prefix)
            for scalar in text.unicodeScalars {
                XCTAssertEqual(mapping.utf8Offset(atUTF16: units), bytes)
                XCTAssertEqual(mapping.utf16Offset(atUTF8: bytes), units)
                for interior in 1..<scalar.utf8.count {
                    XCTAssertEqual(mapping.utf16Offset(atUTF8: bytes + interior), units)
                }
                bytes += scalar.utf8.count
                units += scalar.utf16.count
            }
            XCTAssertEqual(mapping.utf8Offset(atUTF16: units), bytes)
            XCTAssertEqual(mapping.utf16Offset(atUTF8: bytes), units)
            XCTAssertEqual(mapping.utf8Offset(atUTF16: -10), 0)
            XCTAssertEqual(mapping.utf16Offset(atUTF8: bytes + 100), units)
            XCTAssertEqual(mapping.byteCount, text.utf8.count)
        }
    }

    @MainActor func testPaginationCoversChunkWithoutMissingOrRepeatedBytes() {
        let text = String(repeating: "月🌙👨‍👩‍👧‍👦e\u{301}。\n", count: 5)
        let window = ReadingWindow(chunks: [.init(index: 0, startUtf8: 321, endUtf8: 321 + UInt64(text.utf8.count), text: text)])
        let pages = syntheticPages(window)
        XCTAssertGreaterThan(pages.count, 1); assertCoverage(pages, window: window)
        for page in pages { XCTAssertEqual(page.readingText.sourceStart, page.start); XCTAssertEqual(page.readingText.sourceEnd, page.end) }
    }

    @MainActor func testContinuousPaginationFillsPagesAcrossStorageChunks() {
        let chunks = readingChunks(), window = ReadingWindow(chunks: Array(chunks.prefix(3)))
        let pages = syntheticPages(window); assertCoverage(pages, window: window)
        for boundary in chunks.prefix(2).map(\.endUtf8) {
            XCTAssertTrue(pages.contains { $0.start < boundary && $0.end > boundary })
        }
    }

    @MainActor func testSlidingWindowKeepsOverlapPagesWhenMovingForwardAndBackward() {
        let chunks = readingChunks()
        let a = ReadingWindow(chunks: Array(chunks[0...2])), b = ReadingWindow(chunks: Array(chunks[1...3]))
        let first = syntheticPages(a), next = syntheticPages(b, preserving: first)
        let stable = first.filter { $0.start > b.start && $0.end < a.end }
        XCTAssertFalse(stable.isEmpty); assertCoverage(next, window: b)
        let back = syntheticPages(a, preserving: next); assertCoverage(back, window: a)
        for page in stable { XCTAssertTrue(next.contains { $0.start == page.start && $0.end == page.end }); XCTAssertTrue(back.contains { $0.start == page.start && $0.end == page.end }) }
    }

    @MainActor func testDuplicatePageViewsDoNotStealVisibleTextContainer() throws {
        let text = "甲🌙乙", projection = ReadingText(text: "甲🌙乙", sourceStart: 0)
        var page = TextPage(text: NSAttributedString(string: text), start: 0, end: UInt64(text.utf8.count), lineCount: 1, projection: projection)
        page.continuation = NSAttributedString(string: "下一页的lookahead")
        let one = try XCTUnwrap(page.makeTextView(frame: .zero) as? PageReadingTextView)
        let two = try XCTUnwrap(page.makeTextView(frame: .zero) as? PageReadingTextView)
        XCTAssertFalse(one.textStorage === two.textStorage)
        XCTAssertFalse(one.layoutManager === two.layoutManager)
        XCTAssertFalse(one.textContainer === two.textContainer)
        one.selectAll(nil)
        XCTAssertEqual(one.selectedRange, NSRange(location: 0, length: text.utf16.count))
        XCTAssertLessThan(NSMaxRange(one.selectedRange), one.textStorage.length)
        XCTAssertEqual(two.selectedRange.length, 0)
        XCTAssertEqual(one.readingText.coordinates.sourceRange(one.selectedRange), 0..<text.utf8.count)
        XCTAssertEqual(one.accessibilityLabel, text)
    }

    @MainActor func testExpandingEarlierWindowRefillsItsTemporaryLeadingPage() {
        let chunks = readingChunks()
        let a = ReadingWindow(chunks: Array(chunks[1...3])), b = ReadingWindow(chunks: Array(chunks[2...4]))
        let first = syntheticPages(a), later = syntheticPages(b, preserving: first)
        let back = syntheticPages(a, preserving: later); assertCoverage(back, window: a)
        XCTAssertTrue(back.contains { $0.start < b.start && $0.end > b.start })
        var stale = first; for index in stale.indices { stale[index].layoutVersion -= 1 }
        XCTAssertTrue(syntheticPages(a, preserving: stale).allSatisfy { $0.layoutVersion == ReadingTypography.layoutVersion })
    }


    private func syntheticPages(_ window: ReadingWindow, preserving: [TextPage] = [], keeping: UInt64? = nil) -> [TextPage] {
        TextPage.paginate(window, size: .zero, attributes: [:], preserving: preserving, keeping: keeping) { projection, backward in
            let text = projection.text as NSString
            var ranges: [NSRange] = [], cursor = 0
            while cursor < text.length {
                let proposed = NSRange(location: cursor, length: min(37, text.length - cursor))
                let range = text.rangeOfComposedCharacterSequences(for: proposed)
                ranges.append(range); cursor = NSMaxRange(range)
            }
            return ranges
        }
    }

    @MainActor
    private var readingAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .justified
        return [.font: UIFont.systemFont(ofSize: 20), .paragraphStyle: paragraph]
    }

    private func readingChunks() -> [TextChunk] {
        var offset: UInt64 = 0
        return (0..<5).map { index in
            let text = String(repeating: "月亮落在窗边，故事仍在继续。🌙 👨‍👩‍👧‍👦 e\u{301}，读者轻轻翻开下一页。\n", count: 97 + index)
            let end = offset + UInt64(text.utf8.count)
            defer { offset = end }
            return TextChunk(index: UInt32(index), startUtf8: offset, endUtf8: end, text: text)
        }
    }

    @MainActor
    private func assertCoverage(_ pages: [TextPage], window: ReadingWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pages.first?.start, window.start, file: file, line: line)
        XCTAssertEqual(pages.last?.end, window.end, file: file, line: line)
        XCTAssertEqual(pages.map { $0.text.string }.joined(), ReadingText(window).text, file: file, line: line)
        for (page, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(page.end, next.start, file: file, line: line)
            XCTAssertEqual(UInt64(page.text.string.utf8.count), page.end - page.start, file: file, line: line)
        }
    }
}

@MainActor
private final class ThemePreferenceWriterProbe {
    var snapshot = defaultThemeSnapshot()
    var requests: [ThemePreferences] = []
    var started: ((Int) -> Void)?
    private var continuation: CheckedContinuation<ThemeSnapshot, Error>?

    func save(_ value: ThemePreferences) async throws -> ThemeSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requests.append(value)
            started?(requests.count)
        }
    }

    func succeed() {
        snapshot.preferences = requests.last!
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }

    func fail() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CocoaError(.fileWriteUnknown))
    }
}

/// Offline deletion tests inject only filesystem IO/scan; no provider/account is used.
private final class TrashIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var failure: NSError?
    private var scanCount = 0
    static func move(_ url: URL) throws {
        let trash = url.deletingLastPathComponent().appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }
    func record(_ value: String) { lock.withLock { calls.append(value) } }
    func values() -> [String] { lock.withLock { calls } }
    func setFailure(_ error: NSError?) { lock.withLock { failure = error } }
    func scanFailure() -> NSError? { lock.withLock { scanCount += 1; return failure } }
    func scans() -> Int { lock.withLock { scanCount } }
}

private final class TrashScanProbe: @unchecked Sendable {
    struct Job: @unchecked Sendable {
        let entered: XCTestExpectation
        let permit: DispatchSemaphore
        let items: [ScannedLibraryItem]
    }
    private let lock = NSLock()
    private var jobs: [Job] = []
    func enqueue(_ job: Job) { lock.withLock { jobs.append(job) } }
    func scan(_ root: URL) throws -> [ScannedLibraryItem] {
        let job = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst() }
        if let job {
            job.entered.fulfill()
            guard job.permit.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            return job.items
        }
        return try ReaderService.libraryDirectoryItems(root)
    }
}

@MainActor final class LibraryTrashTests: XCTestCase {
    private func fixture(_ names: [String] = ["a.txt"],
                         deletion: @escaping @Sendable (URL, Bool) throws -> Void,
                         scan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil) async throws -> (URL, ReaderCore, ReaderService, [LibraryEntry]) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTrashTests-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("第一章\n" + String(repeating: "离线删除测试。\n", count: 200)).utf8).write(to: url)
        }
        let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: root, sourceDefaultsSuite: "LibraryTrashTests-" + UUID().uuidString,
                                    libraryDeletion: deletion, libraryScan: scan)
        try await service.prepareLibrary(); try await service.scanLibraryShelf("builtin")
        return (temporary, core, service, try await service.libraryEntries(LibraryLocation(shelfID: "builtin")))
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await awaitState(condition)
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testAllTrashFailuresMapToUnsupportedAndPermanentErrorsArePreserved() async throws {
        let probe = TrashIOProbe()
        let (temporary, _, service, entries) = try await fixture(deletion: { _, _ in
            throw probe.scanFailure() ?? NSError(domain: NSCocoaErrorDomain, code: 512)
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cases = [NSError(domain: NSCocoaErrorDomain, code: 3328), NSError(domain: NSCocoaErrorDomain, code: 513),
                     NSError(domain: "Provider", code: 3328), NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]
        for error in cases {
            probe.setFailure(error)
            do { try await service.deleteLibraryItem(entries[0]); XCTFail("Expected injected IO failure") }
            catch LibraryFileError.trashUnsupported { }
            catch { XCTFail("Every trash failure must require the batch decision: \(error)") }
            do { try await service.deleteLibraryItem(entries[0], permanently: true); XCTFail("Permanent failure") }
            catch let actual as NSError { XCTAssertEqual(actual.domain, error.domain); XCTAssertEqual(actual.code, error.code) }
        }
    }

    func testBatchAsksOnceTriesTrashForEveryItemAndResetsAfterCompletion() async throws {
        let probe = TrashIOProbe()
        let (temporary, _, service, entries) = try await fixture(["a.txt", "b.txt", "c.txt"], deletion: { url, permanent in
            probe.record((permanent ? "permanent:" : "trash:") + url.lastPathComponent)
            if !permanent && url.lastPathComponent == "a.txt" { throw NSError(domain: "Provider", code: 91) }
            if !permanent && url.lastPathComponent == "c.txt" { throw CocoaError(.featureUnsupported) }
            // No real deletion needed for the model's injected batch decision contract.
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sorted = entries.sorted { $0.name < $1.name }
        let model = LibraryModel(service: service, fileMutationReload: {})
        var successes: [String] = []
        model.runBatch(sorted.map { .delete($0) }) { successes.append($0.filename) }
        await wait { model.pendingDecision != nil }
        XCTAssertFalse(model.processingFiles)
        let decision = try XCTUnwrap(model.pendingDecision)
        guard case .trashUnsupported = decision else { return XCTFail("A non-3328 failure must pause for the batch decision") }
        XCTAssertEqual(probe.values(), ["trash:a.txt"])
        await model.resolveDecision(decision.id, accepting: true)
        await wait { !model.runningFileBatch }
        XCTAssertEqual(probe.values(), ["trash:a.txt", "permanent:a.txt", "trash:b.txt", "trash:c.txt", "permanent:c.txt"])
        XCTAssertEqual(successes, ["a.txt", "b.txt", "c.txt"])
        // An old dismissal cannot advance the already resolved queue.
        await model.resolveDecision(decision.id, accepting: true)
        XCTAssertEqual(probe.values().count, 5)
        model.runBatch([.delete(sorted[0])])
        await wait { model.pendingDecision != nil }
        XCTAssertNotEqual(model.pendingDecision?.id, decision.id)
        await model.resolveDecision(try XCTUnwrap(model.pendingDecision).id, accepting: false)
        await wait { !model.runningFileBatch }
        XCTAssertEqual(probe.values().last, "trash:a.txt")
    }

    func testReplacementDecisionStillPausesImportQueueAndCancelContinues() async throws {
        let (temporary, _, service, _) = try await fixture(["a.txt", "b.txt"], deletion: { _, _ in })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let incoming = temporary.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let urls = ["a.txt", "b.txt"].map { incoming.appendingPathComponent($0) }
        for url in urls { try Data("replacement text".utf8).write(to: url) }
        let model = LibraryModel(service: service, fileMutationReload: {})
        model.receive(urls)
        await wait { model.pendingDecision != nil }
        let first = try XCTUnwrap(model.pendingDecision)
        guard case .replacement(let command, _) = first else { return XCTFail("Expected a replacement decision") }
        XCTAssertEqual(command.filename, "a.txt")
        await model.resolveDecision(first.id, accepting: false)
        await wait { model.pendingDecision != nil }
        let second = try XCTUnwrap(model.pendingDecision)
        guard case .replacement(let next, _) = second else { return XCTFail("Expected next replacement decision") }
        XCTAssertEqual(next.filename, "b.txt"); XCTAssertNotEqual(second.id, first.id)
        await model.resolveDecision(second.id, accepting: true)
        XCTAssertNil(model.pendingDecision)
        XCTAssertEqual(try String(contentsOf: temporary.appendingPathComponent("library/b.txt"), encoding: .utf8), "replacement text")
        XCTAssertNotEqual(try String(contentsOf: temporary.appendingPathComponent("library/a.txt"), encoding: .utf8), "replacement text")
        model.cancelOpening()
    }

    func testSkipAppliesToAllTrashFailuresAndStillAttemptsEachItem() async throws {
        let probe = TrashIOProbe()
        let (temporary, _, service, entries) = try await fixture(["a.txt", "b.txt", "c.txt", "d.txt"], deletion: { url, permanent in
            probe.record((permanent ? "permanent:" : "trash:") + url.lastPathComponent)
            if url.lastPathComponent == "b.txt" { throw NSError(domain: "Provider", code: 91, userInfo: [NSLocalizedDescriptionKey: "provider error 91"]) }
            if url.lastPathComponent != "c.txt" { throw CocoaError(.featureUnsupported) }
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = LibraryModel(service: service, fileMutationReload: {})
        var successes: [String] = []
        model.runBatch(entries.sorted { $0.name < $1.name }.map { .delete($0) }) { successes.append($0.filename) }
        await wait { model.pendingDecision != nil }
        await model.resolveDecision(try XCTUnwrap(model.pendingDecision).id, accepting: false)
        await wait { !model.runningFileBatch }
        XCTAssertNil(model.pendingDecision)
        XCTAssertEqual(probe.values(), ["trash:a.txt", "trash:b.txt", "trash:c.txt", "trash:d.txt"])
        XCTAssertEqual(successes, ["c.txt"])
        XCTAssertNil(model.error)
    }

    func testFilesystemSuccessSurvivesScan3328AndModelReloadFailureWithoutRetry() async throws {
        let probe = TrashIOProbe()
        let (temporary, _, service, entries) = try await fixture(deletion: { url, permanent in
            probe.record(permanent ? "permanent" : "trash")
            try FileManager.default.removeItem(at: url) // Only this test's fresh temporary fixture.
            probe.setFailure(NSError(domain: NSCocoaErrorDomain, code: 3328))
        }, scan: { root, _ in
            if let error = probe.scanFailure() { throw error }
            return try ReaderService.libraryDirectoryItems(root)
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = LibraryModel(service: service, fileMutationReload: { throw NSError(domain: "Index", code: 7, userInfo: [NSLocalizedDescriptionKey: "reload failed"]) })
        var successes = 0
        model.runBatch([.delete(entries[0])]) { _ in successes += 1 }
        await wait { !model.runningFileBatch }
        XCTAssertEqual(successes, 1); XCTAssertEqual(probe.values(), ["trash"])
        XCTAssertNil(model.pendingDecision); XCTAssertEqual(model.error, "reload failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("library/a.txt").path))
        // A service-level refresh failure stays separate from operation failure too.
        XCTAssertTrue(probe.scans() >= 2)
    }

    func testTrashRootIsMissingWithoutScanOrBookmarkRewriteButTrashyRootIsUsable() async throws {
        let probe = TrashIOProbe()
        let (temporary, core, service, _) = try await fixture(deletion: { _, _ in }, scan: { root, _ in
            probe.record(root.path); return try ReaderService.libraryDirectoryItems(root)
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let deleted = temporary.appendingPathComponent(".Trash/root"), sibling = temporary.appendingPathComponent(".Trashy/root")
        for root in [deleted, sibling] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let id = try await service.registerLibraryShelf(deleted)
        let bookmark = try XCTUnwrap(core.libraryShelves().first { $0.id == id }).bookmark
        let before = probe.values().count
        do { try await service.scanLibraryShelf(id); XCTFail("A trashed root is unavailable") }
        catch LibraryFileError.missingShelf { }
        XCTAssertEqual(probe.values().count, before)
        let shelf = try XCTUnwrap(core.libraryShelves().first { $0.id == id })
        XCTAssertNotNil(shelf.error); XCTAssertEqual(shelf.bookmark, bookmark)
        XCTAssertTrue(shelf.error?.contains("重新连接") == true || shelf.error?.contains("reconnect") == true)
        let other = try await service.registerLibraryShelf(sibling)
        try await service.scanLibraryShelf(other)
        XCTAssertNil(try core.libraryShelves().first { $0.id == other }?.error)
    }

    func testDeletionCancelsSameShelfDescendantButNotSiblingPrefixOrOtherShelf() async throws {
        let (temporary, _, service, entries) = try await fixture(["foo/child.txt", "foobar/child.txt"], deletion: { _, _ in })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let folder = try XCTUnwrap(entries.first { $0.name == "foo" })
        let childEntries = try await service.libraryEntries(folder.location)
        let child = try XCTUnwrap(childEntries.first)
        let siblingEntries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin", path: "foobar"))
        let sibling = try XCTUnwrap(siblingEntries.first)
        let otherRoot = temporary.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot.appendingPathComponent("foo"), withIntermediateDirectories: true)
        try Data("other shelf".utf8).write(to: otherRoot.appendingPathComponent("foo/child.txt"))
        let otherID = try await service.registerLibraryShelf(otherRoot)
        try await service.scanLibraryShelf(otherID)
        let otherEntries = try await service.libraryEntries(LibraryLocation(shelfID: otherID, path: "foo"))
        let other = try XCTUnwrap(otherEntries.first)
        XCTAssertEqual(other.relativePath, child.relativePath)
        for source in [child, sibling, other] {
            let entered = expectation(description: "open preparation entered")
            let gate = SourceReadinessGate(entered: entered)
            let model = LibraryModel(service: service, fileMutationReload: {}, prepareSource: { _, _ in await gate.wait() })
            model.open(source)
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertTrue(model.runBatch([.delete(folder)]))
            await model.waitForFileWork()
            XCTAssertNil(model.error)
            XCTAssertEqual(model.openingFileID, source.id == child.id ? nil : source.id)
            model.cancelOpening(); await gate.release()
        }
    }

    func testDecisionDismissesBeforeContinuingAndCannotContinueTwice() {
        let host = LibraryDecisionAlert.Controller()
        var dismissed: (() -> Void)?, calls = 0
        host.dismissPresentation = { dismissed = $0 }
        host.finish(alert: nil) { calls += 1 }
        host.finish(alert: nil) { XCTFail("Duplicate continuation") }
        XCTAssertEqual(calls, 0)
        dismissed?(); XCTAssertEqual(calls, 1)
    }

    func testDeletionIOCannotBlockCloudPublicationCommitOnReaderActor() async throws {
        let permit = DispatchSemaphore(value: 0), probe = TrashIOProbe()
        let deleting = expectation(description: "delete queue suspended")
        let (temporary, core, service, entries) = try await fixture(deletion: { _, _ in
            probe.record("worker"); deleting.fulfill()
            guard permit.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
        })
        defer { permit.signal(); try? FileManager.default.removeItem(at: temporary) }
        let local = temporary.appendingPathComponent("library"), cloud = temporary.appendingPathComponent("cloud")
        var receipts: [String: CloudHandoffReceipt] = [:]
        try CloudDocumentHandoff.transfer(local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
            persist: { _ in }, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
        let delete = Task { try await service.deleteLibraryItem(entries[0]) }
        await fulfillment(of: [deleting], timeout: 2)
        let committed = expectation(description: "coordinated cloud worker commits through actor while deletion waits")
        let copied = receipts
        let publication = Task {
            var pending = copied
            try await service.publishCloudHandoff(local: local, cloud: cloud, receipts: &pending, persist: { _ in committed.fulfill() })
        }
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(try core.libraryShelves().first?.location, "icloud")
        _ = await service.readingChangeRevision("independent-reader-job")
        permit.signal(); try await publication.value
        let outcome = try await delete.value
        XCTAssertNil(outcome.refreshError)
        XCTAssertEqual(probe.values(), ["worker"])
    }

    func testScansBeforeAndDuringSuspendedDeletionCannotPublishStaleItems() async throws {
        let scan = TrashScanProbe()
        let deleting = expectation(description: "deletion IO suspended")
        let deletePermit = DispatchSemaphore(value: 0)
        let (temporary, core, service, entries) = try await fixture(deletion: { url, _ in
            deleting.fulfill()
            guard deletePermit.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            try FileManager.default.removeItem(at: url)
        }, scan: { root, _ in try scan.scan(root) })
        let beforePermit = DispatchSemaphore(value: 0), duringPermit = DispatchSemaphore(value: 0)
        defer { deletePermit.signal(); beforePermit.signal(); duringPermit.signal(); try? FileManager.default.removeItem(at: temporary) }
        let stale: [ScannedLibraryItem] = [
            .init(relativePath: "a.txt", directory: false, size: 10, modified: 0, needsDownload: false),
            .init(relativePath: "ghost.txt", directory: false, size: 10, modified: 0, needsDownload: false)]
        let beforeEntered = expectation(description: "pre-delete scan captured old items")
        scan.enqueue(.init(entered: beforeEntered, permit: beforePermit, items: stale))
        let before = Task { try await service.scanLibraryShelf("builtin") }
        await fulfillment(of: [beforeEntered], timeout: 2)
        let deletion = Task { try await service.deleteLibraryItem(entries[0]) }
        await fulfillment(of: [deleting], timeout: 2)
        beforePermit.signal(); try await before.value
        XCTAssertEqual(try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["a.txt"], "Deletion invalidates pre-delete scans before suspending IO")
        let duringEntered = expectation(description: "scan captured items while deletion waited")
        scan.enqueue(.init(entered: duringEntered, permit: duringPermit, items: stale))
        let during = Task { try await service.scanLibraryShelf("builtin") }
        await fulfillment(of: [duringEntered], timeout: 2)
        deletePermit.signal()
        let result = try await deletion.value
        XCTAssertNil(result.refreshError)
        duringPermit.signal(); try await during.value
        XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").isEmpty, "The post-success scan invalidates scans begun during deletion")
    }

    func testRestoredFileGetsNewEntryThenSHAReconnectsProgressBookmarkAndNote() async throws {
        let (temporary, core, service, entries) = try await fixture(deletion: { url, _ in
            let trash = url.deletingLastPathComponent().appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        defer { try? FileManager.default.removeItem(at: temporary) }
        let original = entries[0]
        let lease = try await service.openSourceFile(original.source)
        try await service.waitForImportFinish(lease.id)
        let bookID = try XCTUnwrap(core.sourceFileLocation(fileId: original.id).bookId)
        try await service.savePosition(bookID: bookID, offset: 9)
        _ = try await service.toggleBookmark(bookID, at: 9)
        let range = try core.paragraphRange(bookId: bookID, offsetUtf8: 9)
        let edit = try await service.prepareAnnotation(bookID, start: range.startUtf8, end: range.endUtf8)
        _ = try await service.saveNote(edit, text: "删除后保留的笔记")
        let deleted = try await service.deleteLibraryItem(original)
        XCTAssertNil(deleted.refreshError)
        let root = temporary.appendingPathComponent("library")
        try FileManager.default.moveItem(at: root.appendingPathComponent(".Trash/a.txt"), to: root.appendingPathComponent("a.txt"))
        try await service.scanLibraryShelf("builtin")
        let restoredEntries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
        let restored = try XCTUnwrap(restoredEntries.first)
        XCTAssertNotEqual(restored.id, original.id); XCTAssertNil(restored.bookId)
        let reopened = try await service.openSourceFile(restored.source)
        try await service.waitForImportFinish(reopened.id)
        let linked = try await service.libraryEntry(restored.id)
        XCTAssertEqual(linked.bookId, bookID); XCTAssertEqual(linked.positionUtf8, 9)
        let bookmark = try await service.hasBookmark(bookID, at: 9)
        XCTAssertTrue(bookmark)
        let marks = try await service.marks(bookID, kind: .annotation, offset: 0).items
        XCTAssertTrue(marks.contains { $0.note == "删除后保留的笔记" })
        withExtendedLifetime([lease, reopened]) {}
    }
}

private final class IntroductionScanProbe: @unchecked Sendable {
    let entered: [XCTestExpectation]
    let permits = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    private let lock = NSLock()
    private var count = 0
    init(first: XCTestExpectation, second: XCTestExpectation) { entered = [first, second] }
    func scan(_ root: URL) throws -> [ScannedLibraryItem] {
        let index = lock.withLock { let value = count; count += 1; return value }
        if index < 2 {
            entered[index].fulfill()
            guard permits[index].wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
        }
        return try ReaderService.libraryDirectoryItems(root)
    }
}

@MainActor final class ApplicationStateSinkTests: XCTestCase {
    func testSearchPublishesOnlyLatestGenerationAndContentDismissalKeepsScope() async {
        let state = AppSearchResults()
        let old = SearchKey(term: "old", tokens: [], revision: 0, retry: 0, aiAvailable: false)
        let new = SearchKey(term: "new", tokens: [], revision: 0, retry: 0, aiAvailable: false)
        let started = expectation(description: "Old search suspended")
        var release: CheckedContinuation<Void, Never>?
        let pending = Task { await state.run(old, hasCriteria: true) {
            await withCheckedContinuation { release = $0; started.fulfill() }
            throw CocoaError(.fileReadUnknown)
        } }
        await fulfillment(of: [started], timeout: 3)
        await state.run(new, hasCriteria: true) { ([], []) }
        release?.resume(); await pending.value
        XCTAssertEqual(state.completedKey, new); XCTAssertNil(state.error); XCTAssertFalse(state.loading.active)
        let search = AppSearch(tokens: [.shelf("builtin"), .tag("星灯")])
        search.query = " Moonread "; search.keyboardDismissals += 1
        XCTAssertEqual(search.term, "Moonread"); XCTAssertEqual(search.tag, "星灯")
        search.apply(.tag("归途")); XCTAssertEqual(search.tag, "归途"); XCTAssertTrue(search.query.isEmpty)
        await state.run(new, hasCriteria: false) { XCTFail("Empty search must not load"); return ([], []) }
        XCTAssertNil(state.completedKey); XCTAssertTrue(state.entries.isEmpty)
    }
    func testSearchCancelReturnsToActualOriginAndSettingsTabRemainsValid() {
        let model = LibraryModel()
        model.selectedTab = .statistics; model.selectedTab = .search
        model.setSearchPresented(true); model.setSearchPresented(false)
        XCTAssertEqual(model.selectedTab, .statistics)
        model.selectedTab = .conversations; model.updateAvailableTabs(aiAvailable: false)
        XCTAssertEqual(model.selectedTab, .library)
        model.selectedTab = .settings; model.updateAvailableTabs(aiAvailable: true)
        XCTAssertEqual(model.selectedTab, .library)
        let loading = LoadingState(), old = loading.begin(), new = loading.begin()
        loading.finish(old); XCTAssertEqual(loading.request, new)
        loading.finish(new); XCTAssertFalse(loading.active)
    }
    func testOnboardingActionsEmitOnlyTheirOwnInvalidationAndCloseIsAnIntent() throws {
        let name = "OnboardingIntent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var targets = [Onboarding.TipTarget]()
        let model = Onboarding(defaults: defaults, enabled: true, showIntroduction: false, invalidate: { targets.append($0) })
        model.didImport(); model.didImport(); XCTAssertEqual(targets, [.imports])
        model.didShowControls(); XCTAssertEqual(targets, [.imports, .controls])
        model.didSelectText(); XCTAssertEqual(targets, [.imports, .controls, .selection])
        var closed = 0; ThemedTipStyle.close { closed += 1 }; XCTAssertEqual(closed, 1)
        XCTAssertTrue(Onboarding(defaults: defaults, enabled: false).selectedText)
    }
    func testQuickSettingsAndMoreHaveOneReversibleDockState() {
        var dock = ReaderDock.progress
        dock.toggle(.settings); XCTAssertEqual(dock, .settings)
        dock.toggle(.settings); XCTAssertEqual(dock, .progress)
        dock.toggle(.more); dock.toggle(.settings); XCTAssertEqual(dock, .settings)
        dock.toggle(.more); XCTAssertEqual(dock, .more)
        XCTAssertTrue(ReaderPanel.settings.isPage); XCTAssertTrue(ReaderPanel.details.isPage)
        XCTAssertFalse(ReaderPanel.library.isPage)
    }
    func testUndoCountsOnlyVisibleTimeAndRejectsCancelledOldTimer() async {
        let clock = ManualTestClock()
        let tools = ReaderToolsModel(uptime: { .seconds(clock.now.timeIntervalSince1970 - 1_800_000_000) }, sleep: { duration in
            let value = duration.components
            try await clock.sleep(Double(value.seconds) + Double(value.attoseconds) / 1e18)
        })
        tools.deletedIDs = ["mark"]; tools.setUndoVisible(true)
        await awaitState { clock.pendingSleeps == 1 }
        clock.advance(2); tools.setUndoVisible(false); clock.advance(100)
        XCTAssertEqual(tools.deletedIDs, ["mark"])
        tools.setUndoVisible(true); await awaitState { clock.pendingSleeps == 1 }
        clock.advance(3); XCTAssertEqual(tools.deletedIDs, ["mark"])
        clock.advance(1); await awaitState { tools.deletedIDs == nil }
        XCTAssertNil(tools.deletedIDs)
    }
}

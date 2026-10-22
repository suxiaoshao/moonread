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
    func testReaderOpenLargeFixtureRetainsTwentyFourMegabyteScale() {
        let text = ReaderOpenBenchmark.largeFixtureText()
        XCTAssertGreaterThanOrEqual(text.utf8.count, 24_000_000)
        XCTAssertLessThan(text.utf8.count, 24_000_100)
        XCTAssertTrue(text.hasPrefix("第一章 合成\n"))
        XCTAssertTrue(text.hasSuffix("不是小说原文。\n"))
    }
    #endif

    func testRetainedWhitespaceRestoresAndTraversesNativeWindowsBothWays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = "甲标记。" + String(repeating: "　 \t", count: 30000) + "乙标记。\n"
        let file = root.appendingPathComponent("段内空格合成.txt"); try Data(raw.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "段内空格合成")
        let service = ReaderService(core: core)
        let deep = UInt64("甲标记。".utf8.count + 5 * 15000)
        let frame = try await service.frame(book.id, offset: deep)
        XCTAssertEqual(frame.projectionAnchor, deep); XCTAssertEqual(frame.status, .ready)
        XCTAssertFalse(frame.hasNonWhitespacePayload)
        let projection = ReadingText(ReadingWindow(frame: frame))
        let display = try XCTUnwrap(projection.coordinates.displayPoint(Int(deep - projection.sourceStart)))
        XCTAssertEqual(projection.sourceStart + UInt64(try XCTUnwrap(projection.coordinates.sourcePoint(display))), deep)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        for mode in [ReadingMode.scroll, .pages] {
            try await service.savePosition(bookID: book.id, offset: deep)
            let session = ReaderSession(service: service, activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) })
            await session.open(.book(book.id))
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
            await fulfillment(of: [loaded], timeout: 5)
            XCTAssertEqual(session.anchor, deep); XCTAssertEqual(session.window?.projectionAnchor, deep)
            let stored = try await service.snapshot(book.id)
            XCTAssertEqual(stored.book.positionUtf8, deep)
            session.showingCover = false
            let host = UIWindow(windowScene: scene), controller = ReadingController()
            host.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
            host.rootViewController = controller; host.makeKeyAndVisible()
            session.viewportAccess.controller = controller
            controller.requestWindow = { session.requestWindow($0, retaining: $1) }
            var settings = defaultReaderSettings(); settings.mode = mode
            var published: ReadingWindow?
            func configure() {
                guard let value = session.window, value != published else { return }
                controller.configure(window: value, settings: settings, anchor: session.displayAnchor ?? session.anchor, dark: false, typeSize: .large,
                                     compactHeaderHeight: 0, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { session.moved(to: $0, settled: $1) })
                controller.view.frame = host.bounds; controller.view.layoutIfNeeded(); published = value
            }
            func text(_ view: UIView) -> ReadingTextView? {
                if let value = view as? ReadingTextView { return value }
                return view.subviews.lazy.compactMap(text).first
            }
            func active() -> ReadingTextView? {
                if let pager = controller.children.first as? UIPageViewController { return pager.viewControllers?.first?.view as? ReadingTextView }
                return text(controller.view)
            }
            configure()
            XCTAssertNotNil(controller.captureViewport(), "Whitespace-only payload has native line geometry")
            let restoredText = try XCTUnwrap(active())
            let restoredCharacter = try XCTUnwrap(restoredText.readingText.coordinates.displayPoint(Int(deep - restoredText.readingText.sourceStart)))
            let restoredPosition = try XCTUnwrap(restoredText.position(from: restoredText.beginningOfDocument, offset: restoredCharacter))
            XCTAssertTrue(restoredText.caretRect(for: restoredPosition).intersects(restoredText.bounds), "The saved retained-space glyph must be on the restored screen")
            func visible(_ marker: String) -> Bool {
                guard let value = active() else { return false }
                let range = (value.readingText.text as NSString).range(of: marker)
                guard range.location != NSNotFound else { return false }
                let glyphs = value.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = value.layoutManager.boundingRect(forGlyphRange: glyphs, in: value.textContainer)
                    .offsetBy(dx: value.textContainerInset.left, dy: value.textContainerInset.top)
                return rect.height > 0 && rect.intersects(value.bounds)
            }
            for forward in [true, false] {
                var reached = false
                for _ in 0..<1200 {
                    configure()
                    XCTAssertNotNil(controller.captureViewport())
                    if visible(forward ? "乙标记" : "甲标记") { reached = true; break }
                    if let pager = controller.children.first as? UIPageViewController, let current = pager.viewControllers?.first {
                        let next = forward ? controller.pageViewController(pager, viewControllerAfter: current) : controller.pageViewController(pager, viewControllerBefore: current)
                        if let next {
                            pager.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
                            controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [current], transitionCompleted: true)
                        } else { controller.reevaluateWindowRequests() }
                    } else if let value = active() {
                        let maximum = max(0, value.contentSize.height + value.contentInset.bottom - value.bounds.height)
                        value.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, value.contentOffset.y + (forward ? 480 : -480)))), animated: false)
                        controller.scrollViewDidScroll(value); controller.scrollViewDidEndDragging(value, willDecelerate: false)
                    }
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertTrue(reached, "Native \(mode) must traverse retained spaces \(forward ? "forward" : "backward") without a defer loop")
                let item = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.bounds).image { host.layer.render(in: $0.cgContext) })
                item.name = "retained-space-\(mode)-\(forward ? "forward" : "backward")"; item.lifetime = .keepAlways; add(item)
            }
            await session.leave().value; host.isHidden = true
        }
    }

    func testSelectionRangeReaderUnifiesCrossPageCopySearchAIAndCancelsOnLeave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = String(repeating: "甲段用于验证跨页选取的显示正文。\n", count: 40)
        let b = String(repeating: "乙段用于验证跨页选取的显示正文。\n", count: 40)
        let raw = a + String(repeating: " \t　\n", count: 240000) + b
        let file = root.appendingPathComponent("选取合成.txt"); try Data(raw.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "选取合成")
        let service = ReaderService(core: core)
        let session = ReaderSession(service: service, activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) })
        await session.open(.book(book.id))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
        await fulfillment(of: [loaded], timeout: 5)
        let window = try XCTUnwrap(session.window)
        let settings = defaultReaderSettings(), size = CGSize(width: 390, height: 300)
        let pages = TextPage.paginate(window, size: size, attributes: ReadingTypography.attributes(settings, ink: .label), source: ReadingTypography.text(window, settings: settings, ink: .label))
        XCTAssertGreaterThan(pages.count, 2)
        let expected = pages.map { $0.readingText.text }.joined()
        XCTAssertEqual(expected, a + b)
        let last = try XCTUnwrap(pages.last)
        let view = try XCTUnwrap(last.makeTextView(frame: CGRect(origin: .zero, size: size)) as? ReadingTextView)
        session.selectionStart = pages[0].firstVisibleOffset
        let copied = expectation(description: "cross-page native copy is read from the complete envelope")
        view.copySelection = { start, end in
            session.readSelection(start: start, end: end) { range in
                XCTAssertEqual(range.startUtf8, pages[0].firstVisibleOffset)
                XCTAssertEqual(range.endUtf8, book.byteCount)
                UIPasteboard.general.string = range.text
                copied.fulfill()
            }
        }
        UIPasteboard.general.string = "before async copy"
        view.selectAll(nil); view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "before async copy", "No synchronous last-page fallback")
        await fulfillment(of: [copied], timeout: 5)
        XCTAssertEqual(UIPasteboard.general.string, expected)
        session.selectionStart = nil
        let single = try await service.displayTextRange(book.id, start: last.firstVisibleOffset, end: book.byteCount)
        XCTAssertEqual(single.text, last.readingText.text, "Single-page and cross-page use the same Rust projection")
        let cancelled = expectation(description: "selection cannot publish after leave"); cancelled.isInverted = true
        session.readSelection(start: 0, end: book.byteCount) { _ in cancelled.fulfill() }
        await session.leave().value
        await fulfillment(of: [cancelled], timeout: 0.1)
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
    func testBlanksHaveExactlyTheNormalParagraphGapAndNoAccumulatedHeight() throws {
        for gap in [0.0, 7.0, 32.0] {
            var settings = defaultReaderSettings(); settings.paragraphSpacing = gap
            let reference = ReadingTypography.text(try window("甲。\n乙。"), settings: settings, ink: .label)
            let (referenceManager, referenceContainer) = layout(reference)
            let expected = visibleRects(referenceManager, referenceContainer)
            for separator in ["\n", "\n\n\n", " \t　\n", String(repeating: "\n", count: 3000)] {
                let w = try window("甲。\n" + separator + "乙。")
                let source = ReadingTypography.text(w, settings: settings, ink: .label)
                XCTAssertEqual(source.string, ReadingText(w).text)
                let (manager, container) = layout(source)
                let actual = visibleRects(manager, container)
                XCTAssertEqual(actual.count, expected.count)
                for (a, b) in zip(actual, expected) { XCTAssertEqual(a.minY, b.minY, accuracy: 0.0001); XCTAssertEqual(a.height, b.height, accuracy: 0.0001) }
                XCTAssertEqual(manager.usedRect(for: container).height, referenceManager.usedRect(for: referenceContainer).height, accuracy: 0.0001)
                XCTAssertEqual(manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length, source.length)
            }
        }
    }
    func testLeadingTrailingAndHeadingBlanksKeepOnlySemanticSpacing() throws {
        let settings = defaultReaderSettings()
        for content in ["甲。\n乙。", "第一卷 合成\n第1章 标题\n甲。\n乙。"] {
            let clean = ReadingTypography.text(try window(content), settings: settings, ink: .label)
            let padded = ReadingTypography.text(try window("\n\n" + content.replacingOccurrences(of: "\n", with: "\n \t　\n\n") + "\n\n"), settings: settings, ink: .label)
            let (a, ac) = layout(clean), (b, bc) = layout(padded)
            let expected = visibleRects(a, ac), actual = visibleRects(b, bc)
            XCTAssertEqual(actual.count, expected.count)
            for (x, y) in zip(actual, expected) { XCTAssertEqual(x.minY, y.minY, accuracy: 0.0001) }
            // The last visible paragraph owns its spacing; no terminal insertion line.
            XCTAssertEqual(b.extraLineFragmentUsedRect.height, 0)
        }
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

    func testTinyIslandsAcrossManyChunksFitOneViewportInBothModes() throws {
        let gap = String(repeating: " \t　\n", count: 20000)
        let raw = (0..<8).map { "岛\($0)。\n" + gap }.joined()
        let w = try window(raw), projection = ReadingText(w)
        let expected = (0..<8).map { "岛\($0)。\n" }.joined()
        XCTAssertEqual(projection.text, expected)
        XCTAssertGreaterThan(Set(w.chunks.map(\.index)).count, 4)
        let styled = ReadingTypography.text(w, settings: defaultReaderSettings(), ink: .label)
        let view = ReadingTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        view.readingText = projection; view.attributedText = styled; view.layoutIfNeeded()
        view.layoutManager.ensureLayout(for: view.textContainer)
        XCTAssertLessThan(view.layoutManager.usedRect(for: view.textContainer).maxY, view.bounds.height)
        let pages = TextPage.paginate(w, size: view.bounds.size, attributes: [:], source: styled)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.readingText.text, expected)
        XCTAssertEqual(pages.first?.readingText.sourceEnd, projection.sourceEnd)
    }

    func testBusyWindowAdmissionDoesNotConsumeViewportRequest() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene), controller = ReadingController()
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previous?.makeKeyAndVisible() }
        var w = try window("甲段。\n乙段。\n")
        w.nextCursor = w.end
        var admitted = false, accepted: [SourceSpan] = [], attempts = 0
        controller.requestWindow = { direction, keep in
            guard direction == .forward else { return false }
            attempts += 1
            if admitted { accepted.append(keep) }
            return admitted
        }
        var settings = defaultReaderSettings(); settings.mode = .scroll
        controller.configure(window: w, settings: settings, anchor: w.projectionAnchor ?? w.start, dark: false, typeSize: .large,
                             compactHeaderHeight: 0, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
        controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        controller.reevaluateWindowRequests()
        XCTAssertGreaterThan(attempts, 0); XCTAssertTrue(accepted.isEmpty)
        admitted = true
        controller.reevaluateWindowRequests()
        XCTAssertEqual(accepted.count, 1)
        controller.reevaluateWindowRequests()
        XCTAssertEqual(accepted.count, 1, "Unchanged accepted/Deferred tuples are not retried")
        XCTAssertEqual(accepted.first, controller.protectedSourceRange())
    }

    func testFiniteFrameAndProjectionMetricsForOrdinaryAndLongBlankText() throws {
        for (name, raw) in [
            ("ordinary", String(repeating: "普通合成正文，用于窗口与投影测量。\n", count: 3000)),
            ("long-blank", "甲段。\n" + String(repeating: " \t　\n", count: 100000) + "乙段。\n")
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("测量合成.txt"); try Data(raw.utf8).write(to: file)
            let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
            let book = try core.importBook(filePath: file.path, title: "合成")
            let query = try core.querySnapshot(json: "{}")
            var frame = try query.readingFrame(bookId: book.id, offsetUtf8: 0)
            let started = CFAbsoluteTimeGetCurrent()
            for _ in 0..<30 { frame = try query.readingFrame(bookId: book.id, offsetUtf8: 0) }
            let frameMS = (CFAbsoluteTimeGetCurrent() - started) * 1000 / 30
            let w = ReadingWindow(frame: frame)
            let projected = CFAbsoluteTimeGetCurrent()
            for _ in 0..<30 { XCTAssertFalse(ReadingText(w).text.isEmpty) }
            let projectionMS = (CFAbsoluteTimeGetCurrent() - projected) * 1000 / 30
            let bytes = w.chunks.reduce(0) { $0 + $1.text.utf8.count }
            XCTAssertLessThanOrEqual(bytes, 65536)
            XCTAssertLessThanOrEqual(Set(w.chunks.map(\.index)).count, 256)
            print("PROJECTION_METRIC", name, "rawBytes", raw.utf8.count, "retainedBytes", bytes, "frameMeanMS", frameMS, "projectionMeanMS", projectionMS)
        }
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
        for _ in 0..<100 { if session.window != nil { break }; try await Task.sleep(for:.milliseconds(10)) }
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

    func testParagraphBoundaryPrependKeepsTheSameVisibleGlyphAtPixelOffsets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = "正文甲乙丙丁。" + String(repeating: "合成排版验证。", count: 14) + "\n"
        let gap = String(repeating: " \t　\n", count: 40000)
        let raw = gap + "起始甲段。\n" + String(repeating: line, count: 300) + gap + "乙段。\n"
        let target = UInt64(gap.utf8.count + "起始甲段。\n".utf8.count + line.utf8.count * 132)
        XCTAssertEqual(target, 281728)
        let file = root.appendingPathComponent("边界合成.txt"); try Data(raw.utf8).write(to: file)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "合成")
        let query = try core.querySnapshot(json: "{}")
        let service = ReaderService(core: core)
        var reports: [(UInt64, Bool)] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene), controller = ReadingController()
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previous?.makeKeyAndVisible() }
        func native(_ view: UIView) -> ReadingTextView? {
            if let text = view as? ReadingTextView { return text }
            return view.subviews.lazy.compactMap(native).first
        }
        var settings = defaultReaderSettings(); settings.mode = .scroll
        func configure(_ value: ReadingWindow, revision: Int) {
            controller.configure(window: value, settings: settings, anchor: target, dark: false, typeSize: .large,
                                 navigationRevision: revision, navigation: ReadingNavigation(placement: .start),
                                 compactHeaderHeight: 0, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { reports.append(($0, $1)) })
            controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        }
        func rendered(_ name: String) async {
            let ready = expectation(description: name), frames = ReadingScreenshotFrames(ready)
            frames.start(); await fulfillment(of: [ready], timeout: 3)
        }
        var revision = 0
        for direction in [ReadingDirection.forward, .backward] {
            let offset = direction == .forward ? UInt64(gap.utf8.count) : target
            let old = ReadingWindow(frame: try query.readingFrame(bookId: book.id, offsetUtf8: offset))
            let cursor = try XCTUnwrap(direction == .forward ? old.nextCursor : old.previousCursor)
            for delta: Double? in [-1.0, 0, 0.15625, 1.0, nil] {
                revision += 1
                configure(old, revision: revision)
                await rendered("old paragraph frame")
                let text = try XCTUnwrap(native(controller.view))
                let character = try XCTUnwrap(text.readingText.coordinates.displayPoint(Int(target - text.readingText.sourceStart)))
                let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                let rect = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let label = delta.map(String.init(describing:)) ?? "paragraph-gap"
                if let delta {
                    text.setContentOffset(CGPoint(x: 0, y: rect.minY + delta / host.screen.scale), animated: false)
                } else {
                    let prior = text.layoutManager.glyphIndexForCharacter(at: character - 1)
                    let precedingUsed = text.layoutManager.lineFragmentUsedRect(forGlyphAt: prior, effectiveRange: nil)
                    let currentUsed = text.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                    let top = (precedingUsed.maxY + currentUsed.minY) / 2 + 0.25 / host.screen.scale
                    XCTAssertGreaterThan(top, precedingUsed.maxY); XCTAssertLessThan(top, currentUsed.minY)
                    text.setContentOffset(CGPoint(x: 0, y: top + text.textContainerInset.top), animated: false)
                }
                await rendered("positioned paragraph frame")
                let before = try XCTUnwrap(controller.captureViewport())
                XCTAssertEqual(before.offset, target, "A fully visible paragraph wins over a clipped predecessor")
                controller.scrollViewDidEndDragging(text, willDecelerate: false)
                await rendered("settled paragraph frame")
                let saved = try XCTUnwrap(reports.last(where: { $0.1 })?.0)
                XCTAssertEqual(saved, target)
                try await service.savePosition(bookID: book.id, offset: saved)
                let stored = try await service.snapshot(book.id)
                XCTAssertEqual(stored.book.positionUtf8, target)
                func geometry() throws -> (CGFloat, CGFloat) {
                    let character = try XCTUnwrap(text.readingText.coordinates.displayPoint(Int(target - text.readingText.sourceStart)))
                    let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                    let rect = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let location = text.layoutManager.location(forGlyphAt: glyph)
                    let top = text.convert(CGPoint(x: 0, y: rect.minY + text.textContainerInset.top), to: host).y
                    return (top, top + location.y)
                }
                let fixed = try geometry()
                let beforeImage = UIGraphicsImageRenderer(bounds: host.bounds).image { host.layer.render(in: $0.cgContext) }
                let keep = try XCTUnwrap(controller.protectedSourceRange())
                let next = ReadingWindow(frame: try query.readingFrameExtension(bookId: book.id, cursor: cursor, direction: direction, keep: keep))
                XCTAssertEqual(next.status, .ready)
                if direction == .forward { XCTAssertGreaterThan(next.start, old.start) }
                else { XCTAssertLessThan(next.start, old.start) }
                configure(next, revision: revision)
                await rendered("replaced paragraph frame")
                let after = try XCTUnwrap(controller.captureViewport()), restored = try geometry()
                print("PIXEL_ANCHOR", direction, label, "captured", before.offset, before.lineY, after.offset, after.lineY, "fixed", fixed, restored)
                if before.offset != after.offset || abs(before.lineY - after.lineY) > 0.5 {
                    let item = XCTAttachment(image: beforeImage); item.name = "pixel-anchor-before-\(direction)-\(label)"; item.lifetime = .keepAlways; add(item)
                    let image = UIGraphicsImageRenderer(bounds: host.bounds).image { host.layer.render(in: $0.cgContext) }
                    let result = XCTAttachment(image: image); result.name = "pixel-anchor-after-\(direction)-\(label)"; result.lifetime = .keepAlways; add(result)
                }
                XCTAssertEqual(restored.0, fixed.0, accuracy: 0.5)
                XCTAssertEqual(restored.1, fixed.1, accuracy: 0.5)
                XCTAssertEqual(after.offset, before.offset)
                XCTAssertEqual(after.lineY, before.lineY, accuracy: 0.5)
                controller.scrollViewDidEndDragging(text, willDecelerate: false)
                await rendered("saved replacement frame")
                let afterSaved = try XCTUnwrap(reports.last(where: { $0.1 })?.0)
                XCTAssertEqual(afterSaved, target)
                try await service.savePosition(bookID: book.id, offset: afterSaved)
                let afterStored = try await service.snapshot(book.id)
                XCTAssertEqual(afterStored.book.positionUtf8, target)
            }
        }
    }

    func testSessionRustControllerCrossesMultipleWindowsAndLongBlankGapBothWays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let line = "正文甲乙丙丁。"+String(repeating:"合成排版验证。",count:14)+"\n"
        let a = "起始甲段。\n"+String(repeating:line,count:300)+"甲段末尾标记。\n"
        let b = "目标乙段标记。\n"+String(repeating:line,count:180)+"乙段末尾标记。\n"
        XCTAssertGreaterThan(a.utf8.count,4*12*1024)
        let gap = String(repeating:" \t　\n",count:40000)
        let raw = gap+a+gap+b+gap
        let file = root.appendingPathComponent("长空白合成.txt"); try Data(raw.utf8).write(to:file)
        let core = try ReaderCore(dataDirectory:root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath:file.path,title:"合成")
        let service = ReaderService(core:core)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        defer { previousKey?.makeKeyAndVisible() }
        for mode in [ReadingMode.scroll,.pages] {
            for cover in [false,true] {
                try await service.savePosition(bookID:book.id,offset:0)
                let recorder = ReadingActivityRecorder { StatisticsPreferences(enabled:false,generation:0) }
                let session = ReaderSession(service:service,activity:recorder)
                await session.open(.book(book.id))
                for _ in 0..<100 { if session.window != nil { break }; try await Task.sleep(for:.milliseconds(10)) }
                XCTAssertNil(session.error); XCTAssertNotNil(session.window)
                let initialPosition = session.anchor
                let snapshot = try await service.snapshot(book.id)
                XCTAssertEqual(snapshot.book.positionUtf8,initialPosition)
                session.showingCover = cover
                let host = UIWindow(windowScene:scene); host.frame = CGRect(x:0,y:0,width:390,height:650)
                let controller = ReadingController(); host.rootViewController=controller; host.makeKeyAndVisible()
                var settings=defaultReaderSettings(); settings.mode=mode
                session.viewportAccess.controller=controller
                var configuredWindow: ReadingWindow?
                var requests:[ReadingDirection]=[], reports:[UInt64]=[]
                controller.requestWindow = { direction,keep in requests.append(direction); return session.requestWindow(direction,retaining:keep) }
                func fixedGeometry(_ offset: UInt64) -> (CGFloat, CGFloat, String)? {
                    guard let text = activeText(), offset >= text.readingText.sourceStart,
                          let character = text.readingText.coordinates.displayPoint(Int(offset - text.readingText.sourceStart)), character < text.textStorage.length else { return nil }
                    let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                    var line = NSRange()
                    let rect = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
                    let used = text.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                    let location = text.layoutManager.location(forGlyphAt: glyph)
                    let top = rect.minY + text.textContainerInset.top - text.contentOffset.y
                    return (top, top + location.y, "source=\(offset) display=\(character) glyph=\(glyph) line=\(line) fragment=\(rect) used=\(used) location=\(location) inset=\(text.textContainerInset) bounds=\(text.bounds) offset=\(text.contentOffset)")
                }
                func configure() {
                    guard let window=session.window else { return }
                    let changed = configuredWindow != nil && configuredWindow != window
                    let before = changed ? controller.captureViewport() : nil
                    let fixedBefore = before.flatMap { fixedGeometry($0.offset) }
                    let beforeImage = changed ? UIGraphicsImageRenderer(bounds: controller.view.bounds).image { context in
                        controller.view.layer.render(in: context.cgContext)
                    } : nil
                    controller.configure(window:window,settings:settings,anchor:session.displayAnchor ?? session.anchor,dark:false,typeSize:.large,
                        navigationRevision:session.navigationRevision,navigation:session.navigation,
                        coverTitle:cover ? "合成" : nil,showingCover:cover && session.showingCover,
                        coverChanged:{ session.showingCover=$0 },compactHeaderHeight:0,controlsVisible:false,toggleControls:{},readingBegan:{},
                        changed:{ offset,settled in reports.append(offset); session.moved(to:offset,settled:settled) })
                    controller.view.frame=host.bounds; controller.view.layoutIfNeeded()
                    if let before, !before.isCover, let after=controller.captureViewport() {
                        if let fixedBefore, let fixedAfter = fixedGeometry(before.offset) {
                            XCTAssertEqual(fixedAfter.0, fixedBefore.0, accuracy: 0.5, "The same source fragment must not move")
                            XCTAssertEqual(fixedAfter.1, fixedBefore.1, accuracy: 0.5, "The same source glyph baseline must not move")
                            if before.offset != after.offset || abs(before.lineY - after.lineY) > 0.5 {
                                print("ANCHOR_FIXED_BEFORE", fixedBefore.2, "top", fixedBefore.0, "baseline", fixedBefore.1)
                                print("ANCHOR_FIXED_AFTER", fixedAfter.2, "top", fixedAfter.0, "baseline", fixedAfter.1)
                            }
                        }
                        if before.offset != after.offset || abs(before.lineY - after.lineY) > 0.5 {
                            if let beforeImage {
                                let item = XCTAttachment(image: beforeImage); item.name = "window-anchor-before-\(mode)-\(cover)-\(before.offset)"; item.lifetime = .keepAlways; add(item)
                            }
                            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { context in
                                controller.view.layer.render(in: context.cgContext)
                            }
                            let item = XCTAttachment(image: image); item.name = "window-anchor-after-\(mode)-\(cover)-\(after.offset)"; item.lifetime = .keepAlways; add(item)
                        }
                        XCTAssertEqual(after.offset,before.offset,"Extension preserves the actual visible original anchor")
                        XCTAssertEqual(after.lineY,before.lineY,accuracy:0.5,"Extension preserves line baseline")
                    }
                    configuredWindow=window
                }
                configure()
                XCTAssertEqual(session.anchor,initialPosition,"Pure lookup never pretends to read blank ranges")
                func activeText() -> ReadingTextView? {
                    if let pager=controller.children.first(where:{$0 is UIPageViewController}) as? UIPageViewController { return pager.viewControllers?.first?.view as? ReadingTextView }
                    func find(_ view:UIView)->ReadingTextView? { if let text=view as? ReadingTextView { return text }; return view.subviews.lazy.compactMap(find).first }
                    return find(controller.view)
                }
                func isVisible(_ marker:String)->Bool {
                    guard let text=activeText() else { return false }
                    let range=(text.readingText.text as NSString).range(of:marker)
                    guard range.location != NSNotFound else { return false }
                    let glyphs=text.layoutManager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
                    let rect=text.layoutManager.boundingRect(forGlyphRange:glyphs,in:text.textContainer).offsetBy(dx:text.textContainerInset.left,dy:text.textContainerInset.top)
                    return rect.height>0 && rect.intersects(text.bounds)
                }
                func step(_ forward:Bool) {
                    if let pager=controller.children.first(where:{$0 is UIPageViewController}) as? UIPageViewController, let current=pager.viewControllers?.first {
                        let next = forward ? controller.pageViewController(pager,viewControllerAfter:current) : controller.pageViewController(pager,viewControllerBefore:current)
                        if let next { pager.setViewControllers([next],direction:forward ? .forward : .reverse,animated:false); controller.pageViewController(pager,didFinishAnimating:true,previousViewControllers:[current],transitionCompleted:true) }
                        else { controller.reevaluateWindowRequests() }
                    } else if let text=activeText() {
                        let maximum=max(0,text.contentSize.height+text.contentInset.bottom-text.bounds.height)
                        text.setContentOffset(CGPoint(x:0,y:min(maximum,max(0,text.contentOffset.y+(forward ? 480 : -480)))),animated:false)
                        controller.scrollViewDidScroll(text); controller.scrollViewDidEndDragging(text,willDecelerate:false)
                    }
                }
                for (forward,marker) in [(true,"甲段末尾标记"),(true,"目标乙段标记"),(true,"乙段末尾标记"),(false,"甲段末尾标记"),(false,"起始甲段")] {
                    var reached=false
                    for _ in 0..<300 {
                        if isVisible(marker) { reached=true; break }
                        step(forward)
                        for _ in 0..<6 { await Task.yield() }
                        try await Task.sleep(for:.milliseconds(4))
                        configure()
                    }
                    XCTAssertTrue(reached,"\(mode) cover=\(cover) direction=\(forward) target=\(marker), window=\(session.window?.start ?? 0)..<\(session.window?.end ?? 0), next=\(String(describing:session.window?.nextCursor)), scroll=\(String(describing:activeText()?.contentOffset)), size=\(String(describing:activeText()?.contentSize)), range=\(String(describing:activeText().map { ($0.readingText.text as NSString).range(of:marker) })), anchor=\(session.anchor), error=\(session.error ?? "nil")")
                    if forward && marker == "甲段末尾标记" {
                        // Reverse while the lookup cursor is still in the blank
                        // source gap, before B ever becomes the reading viewport.
                        let held = try XCTUnwrap(controller.captureViewport())
                        let actual = session.anchor, count = reports.count
                        let middle=UInt64((gap+a).utf8.count+gap.utf8.count/2)
                        let pending=try await service.extensionFrame(book.id,cursor:middle,direction:.forward)
                        XCTAssertEqual(pending.cursor,middle)
                        session.acceptExtension(pending,direction:.forward); configure()
                        let reverse=try await service.extensionFrame(book.id,cursor:middle,direction:.backward)
                        XCTAssertEqual(reverse.cursor,middle)
                        session.acceptExtension(reverse,direction:.backward); configure()
                        let returned=try XCTUnwrap(controller.captureViewport())
                        XCTAssertTrue(isVisible("甲段末尾标记"))
                        XCTAssertEqual(returned.offset,held.offset); XCTAssertEqual(returned.lineY,held.lineY,accuracy:0.5)
                        XCTAssertEqual(session.anchor,actual); XCTAssertEqual(reports.count,count,"Lookup reversal is not a reading event")
                        let image=UIGraphicsImageRenderer(bounds:host.bounds).image { _ in host.drawHierarchy(in:host.bounds,afterScreenUpdates:true) }
                        let screenshot=XCTAttachment(image:image); screenshot.name="projection-mid-reversal-\(mode)-cover-\(cover)"; screenshot.lifetime = .keepAlways; add(screenshot)
                    }
                    let image=UIGraphicsImageRenderer(bounds:host.bounds).image { _ in host.drawHierarchy(in:host.bounds,afterScreenUpdates:true) }
                    let attachment=XCTAttachment(image:image); attachment.name="projection-\(mode)-cover-\(cover)-\(forward ? "forward" : "backward")"; attachment.lifetime = .keepAlways; add(attachment)
                }
                XCTAssertTrue(requests.contains(.forward)); XCTAssertTrue(requests.contains(.backward))
                XCTAssertTrue(reports.allSatisfy { ($0>=UInt64(gap.utf8.count) && $0<UInt64((gap+a).utf8.count)) || ($0>=UInt64((gap+a+gap).utf8.count) && $0<UInt64((gap+a+gap+b).utf8.count)) },"No blank fetch cursor entered reading reports")
                await session.leave().value; host.isHidden=true
            }
        }
    }

    func testSyntheticBlankLineScreenshots() async throws {
        let text = "\n\n\n第一卷 合成测试\n\n第1章 空行\n\n这里是第一段合成正文，只用于验证阅读排版。\n\n\n\n这里是第二段，前面有连续三个空行。\n \t　\n这里是第三段，前面一行只有空白字符。\n" + String(repeating: "正常段间距应当一致，分页和滚动都不保留空行高度。\n", count: 40)
        let source = try window(text)
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        for mode in [ReadingMode.scroll, .pages] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)
            let host = UIWindow(windowScene: scene); host.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
            let controller = ReadingController()
            host.rootViewController = controller; host.makeKeyAndVisible()
            var settings = defaultReaderSettings(); settings.mode = mode
            controller.configure(window: source, settings: settings, anchor: 0, dark: false, typeSize: .large,
                                 compactHeaderHeight: 0, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.frame = host.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let ready = expectation(description: "Two display frames for screenshot")
            let frames = ReadingScreenshotFrames(ready); frames.start()
            await fulfillment(of: [ready], timeout: 3)
            func nativeTexts(_ view: UIView) -> [UITextView] {
                if let text = view as? UITextView { return [text] }
                return view.subviews.flatMap(nativeTexts)
            }
            let visible = try XCTUnwrap(nativeTexts(controller.view).first { $0.convert($0.bounds, to: controller.view).intersects(controller.view.bounds) })
            XCTAssertTrue(visible.text.hasPrefix(String(ReadingText(source).text.prefix(65))), "Initial page must own the visible title text")
            if mode == .pages { XCTAssertEqual(visible.contentOffset, .zero) }
            for title in ["第一卷 合成测试", "第1章 空行"] {
                let characters = (visible.text as NSString).range(of: title)
                XCTAssertNotEqual(characters.location, NSNotFound)
                let glyphs = visible.layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                let rect = visible.layoutManager.boundingRect(forGlyphRange: glyphs, in: visible.textContainer)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertLessThanOrEqual(rect.maxY + visible.textContainerInset.top, visible.bounds.height)
            }
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in drawn = host.drawHierarchy(in: host.bounds, afterScreenUpdates: true) }
            XCTAssertTrue(drawn, "Screenshot must render the native reading hierarchy")
            let attachment = XCTAttachment(image: image); attachment.name = "blank-lines-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
            host.isHidden = true
        }
        previousKey?.makeKeyAndVisible()
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
        for _ in 0..<100 { if session.window != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let controller = ReadingController()
        host.rootViewController = controller; host.makeKeyAndVisible()
        controller.configure(window: ReadingWindow(chunks: Array(readingChunks()[0...1])), settings: ReaderSettings(mode: .scroll, fontSize: 20, lineSpacing: 8), anchor: 0,
                             dark: false, typeSize: .large, compactHeaderHeight: 22, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(controller.statisticsRange())
        let viewport = ReadingViewportAccess(); viewport.controller = controller
        var written: [ReadingSlice] = []
        let writer = StatisticsWriter { slices, _ in written += slices }
        let entered = expectation(description: "late preferences")
        let gate = SourceReadinessGate(entered: entered)
        let recorder = ReadingActivityRecorder(writer: writer) { await gate.wait(); return StatisticsPreferences(enabled: true, generation: 0) }
        let attempt = UUID(); recorder.prepareStart(attempt)
        recorder.update(readable: true, preview: false)
        let task = Task { await recorder.start(lease: ReadingLease(id: "visible", service: service), viewport: viewport, attempt: attempt) }
        await fulfillment(of: [entered], timeout: 2)
        try await Task.sleep(for: .milliseconds(30))
        recorder.update(readable: false, preview: false) // Scene went inactive while the startup was suspended.
        await gate.release(); await task.value
        try await Task.sleep(for: .milliseconds(30)); await recorder.flush()
        XCTAssertTrue(written.isEmpty, "A late start must not undo the latest inactive/readability state")
        let foreground = Int64(Date().timeIntervalSince1970 * 1000)
        recorder.update(readable: true, preview: false); recorder.interacted()
        try await Task.sleep(for: .milliseconds(30))
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
        for _ in 0..<200 {
            if !(await service.hasRunningImports) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var explicit: ReadingLease? = try await service.restartImport(try XCTUnwrap(first).id, encoding: "utf-16le")
        let taskID = try XCTUnwrap(explicit).id
        for _ in 0..<200 {
            if !(await service.hasRunningImports) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try core.importStatus(bookId: taskID).phase, .complete)
        let cached = try XCTUnwrap(core.sourceBook(key: SourceContentKey(rawSha256: try CloudDocumentHandoff.bytesHash(path), decoding: "UTF-16LE")))
        try await service.savePosition(bookID: taskID, offset: 9)
        first = nil; explicit = nil
        for _ in 0..<200 {
            if UserDefaults(suiteName: suite)?.data(forKey: "Moonread.importSource.library." + taskID) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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
            for _ in 0..<300 {
                if !(await service.hasRunningImports) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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
        for _ in 0..<30 {
            let revision = await service.readingChangeRevision("book")
            let task = Task { try await service.waitForChange("book", after: revision, timeout: .milliseconds(1)) }
            task.cancel(); await service.readingChanged("book")
            do { try await task.value; XCTFail("Cancelled waiter returned success") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        }
        let revision = await service.readingChangeRevision("book")
        try await service.waitForChange("book", after: revision, timeout: .milliseconds(1))
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

    @MainActor
    func testPageAccessibilityActionsUseActiveLocalization() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previous?.makeKeyAndVisible() }
        controller.configure(window: ReadingWindow(chunks: Array(readingChunks()[0...1])),
                             settings: ReaderSettings(mode: .pages, fontSize: 20, lineSpacing: 8), anchor: 0,
                             dark: false, typeSize: .large, compactHeaderHeight: 22,
                             controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
        controller.view.layoutIfNeeded()
        let text = try XCTUnwrap(findReadingText(in: controller.view))
        let actions = text.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertTrue(actions.contains(String(localized: "上一页")), "\(actions)")
        XCTAssertTrue(actions.contains(String(localized: "下一页")), "\(actions)")
    }

    @MainActor
    func testAnnotationTapUsesFullNativeRangeWithoutShowingHandles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let mark = ReaderMark(id: "highlight", kind: .annotation, startUtf8: 0, endUtf8: 9, excerpt: "月亮落", note: "", created: 1)
        func actions(_ menu: UIMenu) -> [UIAction] {
            menu.children.flatMap { ($0 as? UIMenu).map(actions) ?? (($0 as? UIAction).map { [$0] } ?? []) }
        }
        for mode in [ReadingMode.scroll, .pages] {
            let controller = ReadingController()
            host.rootViewController = controller; host.makeKeyAndVisible()
            controller.configure(window: ReadingWindow(chunks: Array(readingChunks()[0...1])),
                                 settings: ReaderSettings(mode: mode, fontSize: 20, lineSpacing: 8), anchor: 0,
                                 dark: false, typeSize: .large, annotations: [mark], compactHeaderHeight: 22,
                                 controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.layoutIfNeeded()
            let text = try XCTUnwrap(findReadingText(in: controller.view))
            let offset = text.contentOffset
            controller.showAnnotationMenu(mark, in: text)
            let expected = NSRange(location: 0, length: 3)
            let completeRange = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in text.selectedRange == expected }, object: nil)
            await fulfillment(of: [completeRange], timeout: 3)
            XCTAssertEqual(text.selectedRange, expected, "Native text tools must use the whole annotation, not just its first word")
            XCTAssertGreaterThan(text.selectedRange.length, 0, "Tap uses a logical native selection for system text actions")
            let display = text.interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }
            XCTAssertFalse(display.isEmpty)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                display.allSatisfy { $0.highlightView.alpha == 0 && $0.handleViews.allSatisfy { $0.alpha == 0 } }
            }, object: nil)
            await fulfillment(of: [hidden], timeout: 2)
            XCTAssertTrue(display.allSatisfy { $0.highlightView.alpha == 0 && $0.handleViews.allSatisfy { $0.alpha == 0 } }, "Tap must hide selection handles")
            XCTAssertEqual(text.contentOffset, offset)
            let menu = controller.selectionMenu(for: AnnotationSelection(start: 0, end: 9, annotations: [mark]), suggestedActions: []) { _ in }
            XCTAssertTrue(actions(menu).contains { $0.title == String(localized: "编辑批注") })
            XCTAssertTrue(actions(menu).contains { $0.title == String(localized: "拷贝") })
            let remove = try XCTUnwrap(actions(menu).first { $0.title == String(localized: "移除批注") })
            XCTAssertTrue(remove.attributes.contains(.destructive))
            // Long-press selection retains its own contextual destructive action.
            let selected = try XCTUnwrap(controller.textView(text, editMenuForTextIn: NSRange(location: 0, length: 3), suggestedActions: []))
            XCTAssertTrue(actions(selected).contains { $0.title == String(localized: "移除批注") && $0.attributes.contains(.destructive) })
            text.interactions.compactMap { $0 as? UIEditMenuInteraction }.forEach { $0.dismissMenu() }
        }
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
        for _ in 0..<100 {
            if !(await service.hasRunningImports) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let key = SourceContentKey(rawSha256: try CloudDocumentHandoff.bytesHash(root.appendingPathComponent("a.txt")), decoding: "auto")
        let cached = try XCTUnwrap(core.sourceBook(key: key), "The first preparation must populate the raw-SHA reuse cache")
        let before = await service.cloudLibraryScheduleRequests
        let lease = try await service.openSourceFile(entry.source)
        for _ in 0..<100 {
            if try core.importStatus(bookId: lease.id).phase == .complete, !(await service.hasRunningImports) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
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

    @MainActor private func waitForMetadataPreparation(_ model: BookInformationModel, until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Metadata preparation did not reach the expected state: \(model.error ?? "no error")")
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
        for _ in 0..<100 {
            if try await service.snapshot(pending).phase == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
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
            for _ in 0..<100 {
                if try await resumed.snapshot(id).phase == .complete { break }
                try await Task.sleep(for: .milliseconds(20))
            }
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let suite = "ImportResultHost-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ai = AIService(defaults: defaults, storefront: .fixed("USA"), reader: service)
        let controller = UIHostingController(rootView: Text("Library").modifier(LibraryPresentations(model: model)).environment(ai))
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previous?.makeKey() }
        model.receive([directory.appendingPathComponent("missing.txt")])
        try await waitForLibraryState { controller.presentedViewController != nil && model.importFailures.count == 1 }
        // Both the Done button and interactive dismissal clear the sheet binding.
        // Exercise the real SwiftUI onDismiss callback without pressing Done.
        model.sheet = nil
        try await waitForLibraryState { controller.presentedViewController == nil && model.importFailures.isEmpty }
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
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.nativeRefreshing, "The pull's spinner stays while the shared refresh runs")
        await probe.gate.release()
        await pull.value
        let passes = await probe.passes
        XCTAssertEqual(passes, 2, "Joining asks for one more pass so the pull sees current files")
        XCTAssertFalse(model.nativeRefreshing)
    }

    @MainActor private func waitForLibraryState(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Library state did not settle", file: file, line: line)
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
            for _ in 0..<200 {
                if try await service.snapshot(id).phase == .complete { return }
                try await Task.sleep(for: .milliseconds(10))
            }
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
            for _ in 0..<200 {
                if try await service.snapshot(id).phase == .complete { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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
            for _ in 0..<200 {
                if defaults.data(forKey: "Moonread.importSource.library.\(id)") == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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
        for _ in 0..<100 { if await restarted.recoveredImports { break }; try await Task.sleep(for: .milliseconds(10)) }
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
        let navigation = UINavigationController()
        navigation.setViewControllers([UIViewController(), controller], animated: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene); host.rootViewController = navigation; host.makeKeyAndVisible()
        defer { host.isHidden = true; previous?.makeKey() }
        controller.update(config()); host.layoutIfNeeded()
        let native = try XCTUnwrap(controller.collectionView)
        let first = IndexPath(item: 0, section: 1), second = IndexPath(item: 1, section: 1)
        native.layoutIfNeeded()
        let firstFrame = try XCTUnwrap(native.layoutAttributesForItem(at: first)).frame
        let secondFrame = try XCTUnwrap(native.layoutAttributesForItem(at: second)).frame
        XCTAssertLessThanOrEqual(firstFrame.maxX, secondFrame.minX)
        XCTAssertLessThanOrEqual(secondFrame.maxX, native.bounds.width - LayoutTokens.page + 1)
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
        native.layoutIfNeeded()
        let row = try XCTUnwrap(native.cellForItem(at: second) as? UICollectionViewListCell)
        let otherRow = try XCTUnwrap(native.cellForItem(at: first))
        XCTAssertEqual(row.frame.height, otherRow.frame.height, accuracy: 1, "Long and short titles use the same row height")
        XCTAssertTrue(row.accessories.contains { $0.accessoryType == .multiselect }, "Selection uses UIKit's native accessory")
        XCTAssertEqual(row.frame.minX, 0, accuracy: 1, "List selection fills the row, rather than drawing inset rounded cards")
        XCTAssertEqual(native.indexPathsForSelectedItems, [second], "Changing layout preserves the UIKit and SwiftUI selection")
        controller.update(config(.list, disabled: true))
        XCTAssertFalse(controller.collectionView(native, shouldBeginMultipleSelectionInteractionAt: first))
        editing = .inactive; selection = []; controller.update(config(.list))
        XCTAssertTrue(native.indexPathsForSelectedItems?.isEmpty ?? true)
    }

    @MainActor func testCoverIsOutsideTextCoordinatesAcrossWindowAndLayoutChanges() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = readingChunks()
        var settings = defaultReaderSettings()
        settings.mode = .scroll
        var revision = 0
        var copied: (UInt64, UInt64)?
        func configure(_ values: [TextChunk], offset: UInt64, cover: Bool, navigation: ReadingNavigation? = nil) {
            if navigation != nil { revision += 1 }
            controller.configure(window: ReadingWindow(chunks: values), settings: settings, anchor: offset,
                                 dark: false, typeSize: .large, navigationRevision: revision, navigation: navigation,
                                 selection: { start, end, action in if action == .copy { copied = (start, end) } },
                                 coverTitle: "月光下的归途", showingCover: cover,
                                 compactHeaderHeight: 22, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.layoutIfNeeded()
        }
        configure(Array(chunks[0...2]), offset: 0, cover: true)
        let text = try XCTUnwrap(findReadingText(in: controller.view))
        XCTAssertEqual(text.contentInset.top, 0)
        XCTAssertEqual(text.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(text.textContainerInset.top, ReadingTextMetrics.insets.top)
        XCTAssertTrue(text.textContainer.exclusionPaths.isEmpty)
        XCTAssertEqual(String(text.text.dropFirst(2)), chunks[0...2].map(\.text).joined())
        XCTAssertFalse(text.isSelectable)
        text.setContentOffset(CGPoint(x: 0, y: 60), animated: false)
        let cover = try XCTUnwrap(controller.captureViewport())
        XCTAssertTrue(cover.isCover)
        configure(Array(chunks[0...2]), offset: 0, cover: false, navigation: ReadingNavigation(placement: .start))
        XCTAssertEqual(text.contentOffset.y, text.bounds.height, accuracy: 1)
        XCTAssertTrue(text.isSelectable)
        let firstBodyGlyph = text.layoutManager.glyphIndexForCharacter(at: 2)
        XCTAssertEqual(text.layoutManager.lineFragmentRect(forGlyphAt: firstBodyGlyph, effectiveRange: nil).minY, text.bounds.height, accuracy: 1)
        let bodyStart = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: 2))
        XCTAssertEqual(text.caretRect(for: bodyStart).minY - text.contentOffset.y,
                       ReadingTextMetrics.insets.top, accuracy: 5,
                       "Native selection and chapter navigation must agree on the first line")
        text.selectAll(nil); text.copy(nil)
        XCTAssertEqual(copied?.0, 0)
        XCTAssertEqual(copied?.1, chunks[2].endUtf8, "Native copy must exclude the synthetic cover")
        text.selectedRange = NSRange(location: 2, length: 0)
        let partialCoverOffset = text.bounds.height * 0.75
        text.setContentOffset(CGPoint(x: 0, y: partialCoverOffset), animated: false)
        let partialCover = try XCTUnwrap(controller.captureViewport())
        XCTAssertFalse(partialCover.isCover)
        XCTAssertEqual(partialCover.offset, 0)
        configure(Array(chunks[0...3]), offset: 0, cover: false)
        XCTAssertEqual(text.contentOffset.y, partialCoverOffset, accuracy: 1,
                       "Replacing a window while the first body line is below the cover must preserve its screen position")
        configure(Array(chunks[0...2]), offset: 0, cover: true, navigation: ReadingNavigation(restoring: cover))
        XCTAssertEqual(text.contentOffset.y, cover.lineY, accuracy: 1)
        settings.fontSize += 4
        configure(Array(chunks[0...2]), offset: 0, cover: true, navigation: ReadingNavigation(restoring: cover))
        let larger = try XCTUnwrap(findReadingText(in: controller.view))
        XCTAssertEqual(larger.contentOffset.y, 0, accuracy: 1)
        configure(Array(chunks[1...3]), offset: chunks[2].startUtf8, cover: false, navigation: ReadingNavigation(placement: .start))
        XCTAssertEqual(try XCTUnwrap(findReadingText(in: controller.view)).contentInset.top, 0)
        configure(Array(chunks[0...2]), offset: 0, cover: true, navigation: ReadingNavigation(placement: .cover))
        let returned = try XCTUnwrap(findReadingText(in: controller.view))
        XCTAssertEqual(returned.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(String(returned.text.dropFirst(2)), chunks[0...2].map(\.text).joined())
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
        for _ in 0..<100 { if session.window != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
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
        for _ in 0..<100 { if !session.navigating { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.showingCover); await session.flush()
        let retainedPosition = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(retainedPosition, position)
        await session.returnFromBrowse()
        XCTAssertFalse(session.showingCover); XCTAssertEqual(session.anchor, position)
        await session.leave().value
        let resumed = ReaderSession(service: service)
        await resumed.open(.book(book.id))
        for _ in 0..<100 { if resumed.window != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
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
        for _ in 0..<100 {
            if !next.path.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        for _ in 0..<200 {
            if try await service.snapshot(id).phase == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
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

    @MainActor
    func testBoundedNativeWindowTurnaroundMetrics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try ReaderCore(dataDirectory: directory.path)
        let source = directory.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        let paragraph = Data((String(repeating: "月亮🌙落在窗边，故事仍在继续，读者翻过下一页。\n", count: 600)).utf8)
        for index in 0..<160 {
            try writer.write(contentsOf: Data("第\(index + 1)章 长路\n".utf8))
            try writer.write(contentsOf: paragraph)
        }
        try writer.close()
        let book = try core.importBook(filePath: source.path, title: "Long window fixture")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let key = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController(); host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; key?.makeKey() }
        let options = XCTMeasureOptions(); options.iterationCount = 3
        var revision = 0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            for index in Array(0..<24) + Array((0..<24).reversed()) {
                autoreleasepool {
                    let offset = book.byteCount * UInt64(index) / 24
                    guard let frame = try? core.querySnapshot(json: "{}").readingFrame(bookId: book.id, offsetUtf8: offset) else { XCTFail("Missing bounded frame"); return }
                    let window = ReadingWindow(frame: frame)
                    revision += 1
                    controller.configure(window: window, settings: defaultReaderSettings(), anchor: offset,
                                         dark: false, typeSize: .large, navigationRevision: revision, navigation: ReadingNavigation(placement: .start),
                                         compactHeaderHeight: 22, controlsVisible: false,
                                         toggleControls: {}, readingBegan: {}, changed: { _, _ in })
                    controller.view.layoutIfNeeded()
                    // Rust bounds payload to 64 KiB across at most 256 source chunks.
                    XCTAssertLessThanOrEqual(window.chunks.count, 256)
                    if let text = findReadingText(in: controller.view) {
                        XCTAssertLessThanOrEqual(text.text.utf8.count, 64 * 1024)
                        XCTAssertTrue(text.text == ReadingText(window).text, "Each measurement must actually replace the rendered window")
                    } else { XCTFail("The visible native text view must survive window replacement") }
                }
            }
        }
    }

    @MainActor
    func testStyledParagraphsPaginateWithoutRepeatingIndentOrClipping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = "第一卷 归来\n第1章 月光\n" + String(repeating: "长段里的月亮🌙和故事，e\u{301}仍在继续。", count: 300) + "\n　　已有缩进。\n\n尾声\n归来。"
        let file = directory.appendingPathComponent("fixture.txt")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: directory.appendingPathComponent("data").path)
        let book = try core.importBook(filePath: file.path, title: "Layout")
        let frame = try core.querySnapshot(json: "{}").readingFrame(bookId: book.id, offsetUtf8: 0)
        let window = ReadingWindow(frame: frame)
        for font in [ReaderFont.system, .serif, .rounded] {
            var settings = defaultReaderSettings(); settings.font = font; settings.horizontalMargin = 24
            let attributed = ReadingTypography.text(window, settings: settings, ink: .label)
            XCTAssertEqual(attributed.string, ReadingText(window).text)
            let heading = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            XCTAssertGreaterThan(heading.pointSize, ReadingTypography.font(settings).pointSize)
            for size in [CGSize(width: 390, height: 650), CGSize(width: 844, height: 290)] {
                let insets = ReadingTypography.insets(settings, width: size.width)
                XCTAssertEqual(insets.left, insets.right)
                XCTAssertLessThanOrEqual(size.width - insets.left - insets.right, settings.maximumLineWidth)
                let pages = TextPage.paginate(window, size: size, attributes: ReadingTypography.attributes(settings, ink: .label), source: attributed, insets: insets)
                assertCoverage(pages, window: window)
                var continuationCount = 0
                for page in pages {
                    if let start = page.text.attribute(.readingParagraphStart, at: 0, effectiveRange: nil) as? NSNumber, start.uint64Value < page.start {
                        let style = try XCTUnwrap(page.layoutText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                        XCTAssertEqual(style.firstLineHeadIndent, 0)
                        XCTAssertEqual(style.paragraphSpacingBefore, 0)
                        continuationCount += 1
                    }
                    let view = page.makeTextView(frame: CGRect(origin: .zero, size: size))
                    view.layoutIfNeeded(); view.layoutManager.ensureLayout(for: view.textContainer)
                    let visible = view.layoutManager.characterRange(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer), actualGlyphRange: nil)
                    XCTAssertEqual(visible.length, page.text.length, "Rendered lines must contain exactly the paginated characters")
                    XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).height, size.height - insets.top - insets.bottom + 1)
                }
                XCTAssertGreaterThan(continuationCount, 2)
            }
        }
    }

    @MainActor
    func testReaderDeviceControlsReleaseAwakeAndOrientationOnBackgroundAndExit() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = UIApplication.shared.isIdleTimerDisabled
        let controls = ReaderDeviceControls()
        defer { controls.stop(); UIApplication.shared.isIdleTimerDisabled = previous }
        var settings = defaultReaderSettings(); settings.keepAwake = true; settings.orientation = .portrait
        controls.update(settings); controls.start(in: scene)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(ReaderDeviceControls.orientationMask(for: scene), .portrait)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, previous)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        controls.stop(); controls.stop()
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, previous)
        XCTAssertEqual(ReaderDeviceControls.orientationMask(for: scene), .allButUpsideDown)
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
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.editor)
        XCTAssertNil(session.selectionStart)
        XCTAssertNil(session.browseOrigin)
        XCTAssertNil(session.error)
        let finalPosition = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(finalPosition, original)
    }

    @MainActor
    func testNavigationPlacesContextKeepsVisibleHitsAndRestoresExactScrollViewport() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = readingChunks()
        let settings = ReaderSettings(mode: .scroll, fontSize: 20, lineSpacing: 8)
        var revision = 0
        func configure(_ chunks: [TextChunk], offset: UInt64, navigation: ReadingNavigation? = nil) {
            if navigation != nil { revision += 1 }
            controller.configure(window: ReadingWindow(chunks: chunks), settings: settings, anchor: offset,
                                 dark: false, typeSize: .large, navigationRevision: revision, navigation: navigation,
                                 focusRange: navigation.map { _ in TextRange(startUtf8: offset, endUtf8: offset + 3, text: "") },
                                 compactHeaderHeight: 22, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.layoutIfNeeded()
        }
        configure(Array(chunks[0...2]), offset: 0)
        let text = try XCTUnwrap(findReadingText(in: controller.view))
        text.setContentOffset(CGPoint(x: 0, y: 287.25), animated: false)
        let origin = try XCTUnwrap(controller.captureViewport())
        let originalOffset = text.contentOffset.y
        func glyphRect(_ offset: UInt64, base: UInt64 = 0) -> CGRect {
            let character = TextCoordinates(text.text).utf16Offset(atUTF8: Int(offset - base))
            let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
            return text.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: text.textContainer)
                .offsetBy(dx: text.textContainerInset.left, dy: text.textContainerInset.top - text.contentOffset.y)
        }
        let originalGlyph = glyphRect(origin.offset)
        let target = chunks[1].startUtf8 + 300
        configure(Array(chunks[0...2]), offset: target, navigation: ReadingNavigation(placement: .context, bottomObstruction: 124))
        XCTAssertTrue(findReadingText(in: controller.view) === text, "A jump in the loaded window must reuse the text view")
        let visibleHeight = text.bounds.height - 16 - 124 - host.safeAreaInsets.bottom - 12
        XCTAssertEqual(glyphRect(target).minY, 16 + visibleHeight / 3, accuracy: 2)
        let positioned = text.contentOffset
        let fullBounds = controller.view.bounds
        for delta in [34.0, 20.0, 4.0, 0.0] {
            controller.view.bounds = CGRect(origin: .zero, size: CGSize(width: fullBounds.width, height: fullBounds.height - delta))
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            XCTAssertTrue(findReadingText(in: controller.view) === text, "Sheet safe-area animation must not rebuild the text")
            XCTAssertEqual(text.contentOffset, positioned, "Sheet height changes must not replace context alignment with top alignment")
        }
        configure(Array(chunks[0...2]), offset: target + 3, navigation: ReadingNavigation(placement: .context, bottomObstruction: 124))
        XCTAssertEqual(text.contentOffset, positioned, "Another clearly visible hit must only change its highlight")
        configure(Array(chunks[0...2]), offset: target, navigation: ReadingNavigation(placement: .start))
        XCTAssertLessThan(glyphRect(target).minY, 30, "Chapter jumps retain the normal top inset")

        configure(Array(chunks[2...4]), offset: chunks[3].startUtf8, navigation: ReadingNavigation(placement: .context))
        XCTAssertTrue(findReadingText(in: controller.view) === text, "A distant jump should replace bounded contents, not the native view")
        configure(Array(chunks[0...2]), offset: origin.offset, navigation: ReadingNavigation(restoring: origin))
        let returned = try XCTUnwrap(controller.captureViewport())
        XCTAssertEqual(returned.offset, origin.offset)
        XCTAssertEqual(glyphRect(origin.offset).minY, originalGlyph.minY, accuracy: 0.5)
        XCTAssertEqual(glyphRect(origin.offset).height, originalGlyph.height, accuracy: 0.5)
        XCTAssertEqual(text.contentOffset.y, originalOffset, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(controller.captureViewport()).lineY, origin.lineY, accuracy: 0.5)
        XCTAssertTrue(findReadingText(in: controller.view) === text)
    }

    @MainActor
    func testNavigationPreservesPageBoundariesAndReturnsAfterDistantJump() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller; host.makeKeyAndVisible()
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = readingChunks()
        let settings = ReaderSettings(mode: .pages, fontSize: 20, lineSpacing: 8)
        var revision = 0
        func configure(_ chunks: [TextChunk], offset: UInt64, navigation: ReadingNavigation? = nil) {
            if navigation != nil { revision += 1 }
            controller.configure(window: ReadingWindow(chunks: chunks), settings: settings, anchor: offset,
                                 dark: false, typeSize: .large, navigationRevision: revision, navigation: navigation,
                                 focusRange: navigation.map { _ in TextRange(startUtf8: offset, endUtf8: offset + 3, text: "") },
                                 compactHeaderHeight: 22, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.layoutIfNeeded()
        }
        configure(Array(chunks[0...2]), offset: 0)
        let layout = try XCTUnwrap(controller.captureViewport())
        let targetPage = layout.pages[3]
        configure(Array(chunks[0...2]), offset: targetPage.start + 90, navigation: ReadingNavigation(placement: .context))
        let origin = try XCTUnwrap(controller.captureViewport())
        XCTAssertEqual(origin.offset, targetPage.start)
        XCTAssertEqual(origin.pages.map(\.start), layout.pages.map(\.start))
        let text = try XCTUnwrap(findReadingText(in: controller.view))
        let contents = text.text
        configure(Array(chunks[0...2]), offset: targetPage.start + 150, navigation: ReadingNavigation(placement: .context))
        XCTAssertTrue(findReadingText(in: controller.view) === text, "Same-page search must preserve the displayed page")
        XCTAssertEqual(text.text, contents)
        configure(Array(chunks[2...4]), offset: chunks[3].startUtf8, navigation: ReadingNavigation(placement: .context))
        configure(Array(chunks[0...2]), offset: origin.offset, navigation: ReadingNavigation(restoring: origin))
        let restored = try XCTUnwrap(controller.captureViewport())
        XCTAssertEqual(restored.offset, origin.offset)
        XCTAssertEqual(restored.pages.map(\.start), origin.pages.map(\.start))
        XCTAssertEqual(findReadingText(in: controller.view)?.text, contents)
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
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
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

    @MainActor
    func testScrollTextFillsBottomSafeAreaAndFinalLineEscapesFade() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller
        host.makeKeyAndVisible()
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        controller.configure(window: ReadingWindow(chunks: Array(readingChunks()[0...1]), isEndOfBook: true),
                             settings: ReaderSettings(mode: .scroll, fontSize: 20, lineSpacing: 8), anchor: 0,
                             dark: false, typeSize: .large, compactHeaderHeight: 22,
                             controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
        controller.view.layoutIfNeeded()
        func findText(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(findText).first
        }
        let text = try XCTUnwrap(findText(controller.view))
        let surface = try XCTUnwrap(text.superview)
        let fade = try XCTUnwrap(surface.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        let viewport = text.convert(text.bounds, to: host)
        let fadeFrame = surface.convert(fade.frame, to: host)
        XCTAssertEqual(viewport.maxY, host.bounds.maxY, accuracy: 0.5,
                       "Text must extend behind the fade all the way to the screen edge")
        XCTAssertEqual(fadeFrame.maxY, host.bounds.maxY, accuracy: 0.5)
        if host.safeAreaInsets.bottom > 0 {
            XCTAssertEqual(fadeFrame.minY, host.bounds.maxY - host.safeAreaInsets.bottom, accuracy: 0.5,
                           "The fade replaces the safe-area gap rather than covering the line above it")
        }
        let underFade = CGRect(x: 0, y: text.bounds.height - fade.frame.height - text.textContainerInset.top,
                               width: text.textContainer.size.width, height: fade.frame.height)
        let glyphs = text.layoutManager.glyphRange(forBoundingRect: underFade, in: text.textContainer)
        XCTAssertGreaterThan(glyphs.length, 0, "The fade must cover actual text, not an empty strip")
        let lastCharacter = (text.text as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards).location
        let lastGlyph = text.layoutManager.glyphIndexForCharacter(at: lastCharacter)
        let lastLine = text.layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        text.setContentOffset(CGPoint(x: 0, y: max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height)), animated: false)
        text.layoutIfNeeded()
        XCTAssertLessThanOrEqual(lastLine.maxY + text.textContainerInset.top - text.contentOffset.y,
                                text.bounds.height - fade.frame.height + 1,
                                "The final line must scroll fully above the gradient")
        XCTAssertEqual(fade.opacity, 0, accuracy: 0.01)
    }

    @MainActor
    func testAppendingAndSlidingTextKeepNativeViewAndVisibleLine() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        let controller = ReadingController()
        host.rootViewController = controller
        host.makeKeyAndVisible()
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = readingChunks()
        let settings = ReaderSettings(mode: .scroll, fontSize: 20, lineSpacing: 8)
        func configure(_ chunks: [TextChunk], at offset: UInt64, marks: [ReaderMark] = []) {
            controller.configure(window: ReadingWindow(chunks: chunks), settings: settings, anchor: offset,
                                 dark: false, typeSize: .large, annotations: marks, compactHeaderHeight: 22,
                                 controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
            controller.view.layoutIfNeeded()
        }
        func findText(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap(findText).first
        }
        configure(Array(chunks[0...1]), at: 0)
        let text = try XCTUnwrap(findText(controller.view))
        XCTAssertEqual(text.layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).maxX,
                       text.textContainer.size.width, accuracy: 1)
        text.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        let markedText = String(chunks[0].text.prefix { $0 != "\n" }) + "\n月"
        let mark = ReaderMark(id: "test", kind: .annotation, startUtf8: 0, endUtf8: UInt64(markedText.utf8.count),
                              excerpt: markedText, note: "Note", created: 0)
        configure(Array(chunks[0...1]), at: 0, marks: [mark])
        XCTAssertEqual(text.contentOffset.y, 180, accuracy: 1, "Decorating a range must not move the reading viewport")
        XCTAssertNil(text.textStorage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let layout = try XCTUnwrap(text.layoutManager as? ReadingLayoutManager)
        XCTAssertNil(text.textStorage.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                     "Permanent highlights must not use the full line-height native background")
        let fills = layout.decorationBackgrounds(forGlyphRange: layout.glyphRange(for: text.textContainer))
        XCTAssertFalse(fills.isEmpty)
        for fill in fills {
            XCTAssertEqual(fill.rect.height, 20, accuracy: 0.5)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                let image = UIGraphicsImageRenderer(size: CGSize(width: text.bounds.width, height: 190)).image { context in
                    ThemeSurface.initial.paper.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: text.bounds.width, height: 190))
                    let visible = layout.glyphRange(forBoundingRect: CGRect(x: 0, y: 0, width: text.textContainer.size.width, height: 170), in: text.textContainer)
                    let origin = CGPoint(x: text.textContainerInset.left, y: text.textContainerInset.top)
                    layout.drawBackground(forGlyphRange: visible, at: origin)
                    layout.drawGlyphs(forGlyphRange: visible, at: origin)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = style == .dark ? "annotation-band-dark" : "annotation-band-light"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let newline = (text.text as NSString).range(of: "\n").location
        XCTAssertFalse(layout.decorations.contains { NSLocationInRange(newline, $0.range) },
                     "A cross-paragraph annotation must not paint paragraph spacing")
        XCTAssertTrue(layout.decorations.contains { NSLocationInRange(newline + 1, $0.range) })
        let highlightedGlyph = text.layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer)
        let hit = CGPoint(x: highlightedGlyph.midX + text.textContainerInset.left, y: highlightedGlyph.midY + text.textContainerInset.top)
        XCTAssertEqual(controller.annotationIDs(at: hit, in: text), [mark.id])
        XCTAssertTrue(controller.annotationIDs(at: CGPoint(x: 1, y: hit.y), in: text).isEmpty, "Blank margins must not activate a highlight")
        XCTAssertTrue(text.subviews.compactMap { $0 as? UIButton }.isEmpty, "Annotations must not add gutter buttons")
        let originalDocument = text.text
        let selected = NSRange(location: 10, length: 6)
        text.selectedRange = selected
        configure(Array(chunks[0...2]), at: 0)
        XCTAssertEqual(text.text, originalDocument, "Background window growth must not edit a native selection's document")
        XCTAssertEqual(text.selectedRange, selected)
        text.selectedRange = NSRange(location: selected.location, length: 0)
        controller.textViewDidChangeSelection(text)
        let appended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { text.text == chunks[0...2].map(\.text).joined() }
        }, object: nil)
        await fulfillment(of: [appended], timeout: 3)
        XCTAssertTrue(layout.decorationBackgrounds(forGlyphRange: layout.glyphRange(for: text.textContainer)).isEmpty)
        XCTAssertTrue(findText(controller.view) === text)
        XCTAssertEqual(text.contentOffset.y, 180, accuracy: 1)
        let semantic = chunks[1].startUtf8 + 120
        let oldCoordinates = TextCoordinates(text.text)
        let character = oldCoordinates.utf16Offset(atUTF8: Int(semantic))
        let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
        let line = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        text.setContentOffset(CGPoint(x: 0, y: line.minY + 4), animated: false)
        configure(Array(chunks[1...3]), at: semantic)
        XCTAssertTrue(findText(controller.view) === text)
        let newCoordinates = TextCoordinates(text.text)
        let newCharacter = newCoordinates.utf16Offset(atUTF8: Int(semantic - chunks[1].startUtf8))
        let newGlyph = text.layoutManager.glyphIndexForCharacter(at: newCharacter)
        let newLine = text.layoutManager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil)
        XCTAssertEqual(newLine.minY - text.contentOffset.y, -4, accuracy: 1,
                       "A window handoff must preserve the visible line's screen position")
        // TextKit and UIScrollView may finish layout on a later main-loop turn.
        // The immediate offset alone does not prove the reading position held.
        try await Task.sleep(for: .milliseconds(150))
        text.layoutIfNeeded()
        let settledLine = text.layoutManager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil)
        XCTAssertEqual(settledLine.minY - text.contentOffset.y, -4, accuracy: 1,
                       "Deferred native layout must not move the line after the handoff")
    }

    @MainActor
    func testBookmarksFollowGlyphLinesThroughReflowScrollAndPageBoundaries() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = Array(readingChunks()[0...1])
        // A bookmark after an emoji exercises UTF-8/UTF-16 mapping too.
        let source = chunks[0].text
        let target = UInt64(source[..<source.range(of: "读者")!.lowerBound].utf8.count)
        for mode in [ReadingMode.scroll, .pages] {
            let controller = ReadingController()
            host.rootViewController = controller; host.makeKeyAndVisible()
            func configure(_ positions: [UInt64], size: Double = 20, dark: Bool = false) throws -> ReadingTextView {
                controller.configure(window: ReadingWindow(chunks: chunks),
                                     settings: ReaderSettings(mode: mode, fontSize: size, lineSpacing: 8), anchor: 0,
                                     dark: dark, typeSize: .large, bookmarkPositions: positions,
                                     compactHeaderHeight: 22, controlsVisible: false, toggleControls: {},
                                     readingBegan: {}, changed: { _, _ in })
                controller.view.layoutIfNeeded()
                let text = try XCTUnwrap(findReadingText(in: controller.view) as? ReadingTextView)
                text.layoutIfNeeded()
                return text
            }
            func assertAligned(_ text: ReadingTextView, at offset: UInt64) throws {
                let indicator = try XCTUnwrap(text.bookmarkIndicators.first)
                let character = TextCoordinates(text.text).utf16Offset(atUTF8: Int(offset))
                let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                let line = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    .offsetBy(dx: text.textContainerInset.left, dy: text.textContainerInset.top)
                XCTAssertGreaterThan(indicator.frame.minX, text.bounds.width - text.textContainerInset.right)
                XCTAssertLessThanOrEqual(indicator.frame.maxX, text.bounds.width)
                XCTAssertGreaterThanOrEqual(indicator.frame.midY, line.minY)
                XCTAssertLessThan(indicator.frame.midY, line.maxY)
                XCTAssertFalse(indicator.isUserInteractionEnabled)
            }
            let text = try configure([])
            let original = NSAttributedString(attributedString: text.textStorage)
            let frame = text.frame
            let originalGlyphs = text.layoutManager.glyphRange(for: text.textContainer)
            XCTAssertTrue(try configure([0, 3]) === text)
            XCTAssertEqual(text.bookmarkIndicators.count, 1, "Same-line bookmarks share one indicator")
            try assertAligned(text, at: 0)
            _ = try configure([target])
            try assertAligned(text, at: target)
            let firstY = try XCTUnwrap(text.bookmarkIndicators.first).frame.minY
            _ = try configure([target], dark: true)
            XCTAssertEqual(text.bookmarkIndicators.first?.frame.minY, firstY)
            XCTAssertEqual(text.frame, frame)
            XCTAssertTrue(text.textStorage.isEqual(to: original), "Markers never become part of selectable text")
            XCTAssertEqual(text.layoutManager.glyphRange(for: text.textContainer), originalGlyphs)
            if mode == .scroll {
                let originalScreenY = text.bookmarkIndicators[0].convert(text.bookmarkIndicators[0].bounds, to: host).minY
                text.setContentOffset(CGPoint(x: 0, y: 8), animated: false); text.layoutIfNeeded()
                let movedScreenY = text.bookmarkIndicators[0].convert(text.bookmarkIndicators[0].bounds, to: host).minY
                XCTAssertEqual(movedScreenY, originalScreenY - 8, accuracy: 0.5)
                text.setContentOffset(CGPoint(x: 0, y: 400), animated: false); text.layoutIfNeeded()
                XCTAssertTrue(text.bookmarkIndicators.isEmpty, "Offscreen indicators are released")
                text.setContentOffset(.zero, animated: false); text.layoutIfNeeded()
                try assertAligned(text, at: target)
            } else {
                let visibleLength = try XCTUnwrap((text as? PageReadingTextView)?.visibleLength)
                let nextPage = UInt64(TextCoordinates(text.text).utf8Offset(atUTF16: visibleLength))
                _ = try configure([nextPage])
                XCTAssertTrue(text.bookmarkIndicators.isEmpty, "Lookahead bookmarks belong to the next page")
            }
            let larger = try configure([target], size: 28)
            try assertAligned(larger, at: target)
            XCTAssertEqual(larger.textContainerInset, ReadingTextMetrics.insets)
            _ = try configure([], size: 28)
            XCTAssertTrue(larger.bookmarkIndicators.isEmpty)
        }
    }

    @MainActor
    func testHighlightChangesNeverEditTextOrMoveSelectionAndViewport() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIWindow(windowScene: scene)
        defer { host.isHidden = true; previousKey?.makeKeyAndVisible() }
        let chunks = Array(readingChunks()[0...1])
        let mark = ReaderMark(id: "paint", kind: .annotation, startUtf8: 0, endUtf8: 90,
                              excerpt: "月亮", note: "", created: 0)
        for mode in [ReadingMode.scroll, .pages] {
            let controller = ReadingController()
            host.rootViewController = controller
            host.makeKeyAndVisible()
            func configure(marks: [ReaderMark] = [], bookmarks: [UInt64] = [], focus: TextRange? = nil, dark: Bool = false, theme: ThemeSurface? = nil) {
                controller.configure(window: ReadingWindow(chunks: chunks),
                                     settings: ReaderSettings(mode: mode, fontSize: 20, lineSpacing: 8), anchor: 0,
                                     dark: dark, typeSize: .large, theme: theme, annotations: marks, bookmarkPositions: bookmarks, focusRange: focus,
                                     compactHeaderHeight: 22, controlsVisible: false, toggleControls: {},
                                     readingBegan: {}, changed: { _, _ in })
                controller.view.layoutIfNeeded()
            }
            func findText(_ view: UIView) -> UITextView? {
                if let text = view as? UITextView { return text }
                return view.subviews.lazy.compactMap(findText).first
            }
            configure()
            let text = try XCTUnwrap(findText(controller.view))
            let layout = try XCTUnwrap(text.layoutManager as? ReadingLayoutManager)
            text.selectedRange = NSRange(location: 5, length: 0)
            if mode == .scroll { text.setContentOffset(CGPoint(x: 0, y: 180), animated: false) }
            // Let any setup selection reveal finish before measuring decoration updates.
            try await Task.sleep(for: .milliseconds(150))
            let offset = text.contentOffset
            let selection = text.selectedRange
            let originalText = NSAttributedString(attributedString: text.textStorage)
            let firstGlyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer)
            for change in 0..<6 {
                let noEdits = XCTNSNotificationExpectation(name: NSTextStorage.didProcessEditingNotification, object: text.textStorage)
                noEdits.isInverted = true
                switch change {
                case 0: configure(marks: [mark])
                case 1: layout.setDecorations(layout.decorations.map { .init(range: $0.range, color: .systemPink) })
                case 2: configure(marks: [mark], focus: TextRange(startUtf8: 30, endUtf8: 60, text: ""))
                case 3: configure(marks: [mark], dark: true)
                case 4: configure(marks: [mark], bookmarks: [0, 30])
                default: configure()
                }
                // Check after the run loop, including deferred native selection scrolling.
                await fulfillment(of: [noEdits], timeout: 0.2)
                XCTAssertTrue(findText(controller.view) === text, "Appearance must retain the native reader")
                XCTAssertTrue(text.textStorage.isEqual(to: originalText))
                XCTAssertEqual(text.selectedRange, selection)
                XCTAssertEqual(text.contentOffset, offset)
                XCTAssertEqual(layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer), firstGlyph)
            }
            XCTAssertTrue(layout.decorations.isEmpty)
            for palette in builtinThemePalettes() {
                let colors = palette.colors
                let surface = ThemeSurface(plan: ResolvedTheme(appearance: palette.appearance, highContrast: false, colors: colors, paletteId: palette.id))
                let noEdits = XCTNSNotificationExpectation(name: NSTextStorage.didProcessEditingNotification, object: text.textStorage)
                noEdits.isInverted = true
                configure(theme: surface)
                await fulfillment(of: [noEdits], timeout: 0.1)
                XCTAssertTrue(findText(controller.view) === text)
                XCTAssertEqual(text.contentOffset, offset)
                XCTAssertEqual(text.selectedRange, selection)
                XCTAssertEqual(text.backgroundColor, surface.paper)
                let ink = try XCTUnwrap(text.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
                XCTAssertEqual(ink.resolvedColor(with: controller.traitCollection), surface.ink)
                XCTAssertEqual(layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: text.textContainer), firstGlyph)
            }
        }
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

    @MainActor
    func testPaginationCoversChunkWithoutMissingOrRepeatedBytes() {
        let content = String(repeating: "月亮落在窗边，故事仍在继续。🌙 👨‍👩‍👧‍👦 e\u{301}\n", count: 180)
        let start: UInt64 = 321
        let chunk = TextChunk(index: 2, startUtf8: start, endUtf8: start + UInt64(content.utf8.count), text: content)
        for size in [CGSize(width: 375, height: 650), CGSize(width: 680, height: 270)] {
            for fontSize in [16.0, 32.0, 48.0] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 8
                let pages = TextPage.paginate(chunk, size: size, attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph
                ])
                XCTAssertGreaterThan(pages.count, 1)
                XCTAssertEqual(pages.first?.start, start)
                XCTAssertEqual(pages.last?.end, chunk.endUtf8)
                for (page, next) in zip(pages, pages.dropFirst()) {
                    XCTAssertEqual(page.end, next.start)
                    XCTAssertLessThan(page.start, page.end)
                }
            }
        }
    }

    @MainActor
    func testContinuousPaginationFillsPagesAcrossStorageChunks() {
        let chunks = readingChunks()
        let window = ReadingWindow(chunks: Array(chunks.prefix(3)))
        let size = CGSize(width: 390, height: 690)
        let pages = TextPage.paginate(window, size: size, attributes: readingAttributes)
        assertCoverage(pages, window: window)
        for boundary in chunks.prefix(2).map(\.endUtf8) {
            XCTAssertTrue(pages.contains { $0.start < boundary && $0.end > boundary },
                          "A storage boundary must not force a page break")
        }
        for page in pages.dropLast() {
            let view = page.makeTextView(frame: CGRect(origin: .zero, size: size))
            view.layoutIfNeeded()
            view.layoutManager.ensureLayout(for: view.textContainer)
            let used = view.layoutManager.usedRect(for: view.textContainer)
            XCTAssertGreaterThan(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom - 70, "An interior page should fill its reading area")
            XCTAssertLessThanOrEqual(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom + 1, "Page text must fit, not be clipped")
        }
    }

    @MainActor
    func testSlidingWindowKeepsOverlapPagesWhenMovingForwardAndBackward() {
        let chunks = readingChunks()
        let size = CGSize(width: 390, height: 690)
        let firstWindow = ReadingWindow(chunks: Array(chunks[0...2]))
        let forwardWindow = ReadingWindow(chunks: Array(chunks[1...3]))
        let first = TextPage.paginate(firstWindow, size: size, attributes: readingAttributes)
        let forward = TextPage.paginate(forwardWindow, size: size, attributes: readingAttributes, preserving: first)
        assertCoverage(forward, window: forwardWindow)
        let stable = first.filter { $0.start >= chunks[1].startUtf8 && $0.end <= chunks[2].startUtf8 }
        XCTAssertFalse(stable.isEmpty)
        for page in stable {
            XCTAssertTrue(forward.contains { $0.start == page.start && $0.end == page.end && $0.text == page.text })
        }
        let backward = TextPage.paginate(firstWindow, size: size, attributes: readingAttributes, preserving: forward)
        assertCoverage(backward, window: firstWindow)
        for page in stable {
            XCTAssertTrue(backward.contains { $0.start == page.start && $0.end == page.end && $0.text == page.text })
        }
        for page in backward.dropFirst().dropLast() {
            let view = page.makeTextView(frame: CGRect(origin: .zero, size: size))
            view.layoutIfNeeded()
            view.layoutManager.ensureLayout(for: view.textContainer)
            let used = view.layoutManager.usedRect(for: view.textContainer)
            XCTAssertGreaterThan(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom - 70)
            XCTAssertLessThanOrEqual(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom + 1)
        }
    }

    @MainActor
    func testDuplicatePageViewsDoNotStealVisibleTextContainer() {
        let chunk = readingChunks()[0]
        let size = CGSize(width: 390, height: 690)
        let page = TextPage.paginate(chunk, size: size, attributes: readingAttributes)[0]
        let first = page.makeTextView(frame: CGRect(origin: .zero, size: size))
        let second = page.makeTextView(frame: CGRect(origin: .zero, size: size))
        first.layoutIfNeeded()
        second.layoutIfNeeded()
        XCTAssertFalse(first.textContainer === second.textContainer)
        XCTAssertTrue(first.layoutManager.textContainers.contains { $0 === first.textContainer })
        XCTAssertTrue(second.layoutManager.textContainers.contains { $0 === second.textContainer })
        XCTAssertFalse(first.layoutManager === second.layoutManager)
        XCTAssertEqual(first.textStorage.attributedSubstring(from: NSRange(location: 0, length: page.text.length)).string, page.text.string)
        first.selectAll(nil)
        XCTAssertEqual(first.selectedRange, NSRange(location: 0, length: page.text.length))
        XCTAssertEqual(second.accessibilityLabel, page.text.string)
        first.selectedTextRange = first.textRange(from: first.beginningOfDocument, to: first.endOfDocument)
        XCTAssertEqual(first.selectedRange, NSRange(location: 0, length: page.text.length),
                       "Dragging a selection cannot include the invisible typesetting lookahead")
        first.layoutManager.ensureLayout(for: first.textContainer)
        XCTAssertGreaterThan(first.layoutManager.usedRect(for: first.textContainer).height, 0)
    }

    @MainActor
    func testExpandingEarlierWindowRefillsItsTemporaryLeadingPage() {
        let chunks = readingChunks()
        let size = CGSize(width: 390, height: 690)
        let initialWindow = ReadingWindow(chunks: Array(chunks[0...2]))
        let middleWindow = ReadingWindow(chunks: Array(chunks[1...3]))
        let laterWindow = ReadingWindow(chunks: Array(chunks[2...4]))
        let initial = TextPage.paginate(initialWindow, size: size, attributes: readingAttributes)
        let middle = TextPage.paginate(middleWindow, size: size, attributes: readingAttributes, preserving: initial)
        let later = TextPage.paginate(laterWindow, size: size, attributes: readingAttributes, preserving: middle)
        let returned = TextPage.paginate(middleWindow, size: size, attributes: readingAttributes, preserving: later)
        assertCoverage(returned, window: middleWindow)
        let oldLeadingStart = later.first!.start
        XCTAssertTrue(returned.contains { $0.start < oldLeadingStart && $0.end > oldLeadingStart },
                      "The old leading storage edge must become ordinary text inside a full page")
        for page in returned.dropFirst().dropLast() {
            let view = page.makeTextView(frame: CGRect(origin: .zero, size: size))
            view.layoutIfNeeded()
            view.layoutManager.ensureLayout(for: view.textContainer)
            let range = view.layoutManager.characterRange(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer), actualGlyphRange: nil)
            XCTAssertEqual(range, NSRange(location: 0, length: page.text.length))
            let used = view.layoutManager.usedRect(for: view.textContainer)
            XCTAssertGreaterThan(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom - 70)
            XCTAssertLessThanOrEqual(used.height, size.height - ReadingTextMetrics.insets.top - ReadingTextMetrics.insets.bottom + 1)
        }
    }

    @MainActor
    func testJustificationFillsWrappedLinesAndLeavesParagraphEndNatural() {
        let content = String(repeating: "月亮落在窗边，故事仍在继续，读者轻轻翻开下一页。", count: 20) + "终。"
        let size = CGSize(width: 390, height: 690)
        let chunk = TextChunk(index: 0, startUtf8: 0, endUtf8: UInt64(content.utf8.count), text: content)
        let pages = TextPage.paginate(chunk, size: size, attributes: readingAttributes)
        for page in pages {
            let view = page.makeTextView(frame: CGRect(origin: .zero, size: size))
            view.layoutManager.ensureLayout(for: view.textContainer)
            var lines: [CGRect] = []
            view.layoutManager.enumerateLineFragments(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer)) { _, used, _, _, _ in
                lines.append(used)
            }
            for line in lines.dropLast() {
                XCTAssertEqual(line.maxX, ReadingTextMetrics.contentSize(in: size).width, accuracy: 1)
            }
            let visible = view.layoutManager.characterRange(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer), actualGlyphRange: nil)
            XCTAssertEqual(visible, NSRange(location: 0, length: page.text.length))
            if page.end == chunk.endUtf8, let line = lines.last {
                XCTAssertLessThan(line.maxX, ReadingTextMetrics.contentSize(in: size).width - 1,
                                  "The real paragraph ending must not be stretched")
            }
            if page.end < chunk.endUtf8, let line = lines.last {
                XCTAssertEqual(line.maxX, ReadingTextMetrics.contentSize(in: size).width, accuracy: 1,
                               "A page boundary inside a paragraph is still a wrapped line")
            }
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
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

    func testDecisionDismissesBeforeContinuingAndCannotContinueTwice() async throws {
        let host = LibraryDecisionAlert.Controller()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let alert = UIAlertController(title: "decision", message: nil, preferredStyle: .alert)
        let presented = expectation(description: "presented")
        host.present(alert, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 2)
        let dismissed = expectation(description: "continuation after UIKit dismissal")
        var calls = 0
        host.finish(alert: alert) {
            calls += 1
            XCTAssertNil(alert.presentingViewController); XCTAssertNil(host.presentedViewController)
            dismissed.fulfill()
        }
        host.finish(alert: alert) { XCTFail("Duplicate dismissal continuation") }
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertEqual(calls, 1)
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
        for _ in 0..<200 {
            if try await service.snapshot(lease.id).phase == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        for _ in 0..<200 {
            if try await service.snapshot(reopened.id).phase == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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

import AVFoundation
import XCTest
import UIKit
@testable import Moonread

@MainActor final class ListeningTests: XCTestCase {
    func testBoundedSpeechUsesSharedProjectionAndOriginalUTF8Coordinates() throws {
        let raw = "　　原创甲😀，original text。\n\n\t原创乙。\n"
        let firstEnd = UInt64("　　原创甲😀，original text。\n".utf8.count)
        let secondStart = firstEnd + 1, end = UInt64(raw.utf8.count)
        let window = ReadingWindow(chunks: [.init(index: 0, startUtf8: 100, endUtf8: 100 + end, text: raw)], paragraphs: [
            .init(startUtf8: 100, endUtf8: 100 + firstEnd, kind: .body, continuation: false, indented: true),
            .init(startUtf8: 100 + firstEnd, endUtf8: 100 + secondStart, kind: .blank, continuation: false, indented: false),
            .init(startUtf8: 100 + secondStart, endUtf8: 100 + end, kind: .body, continuation: false, indented: true)
        ], isEndOfBook: true)
        let projection = ReadingText(window, indent: .smart)
        var cursor: UInt64 = 100, spoken = ""
        var segments = 0
        while let segment = ListeningTextProvider.segment(in: window, at: cursor, paragraphStart: false, indent: .smart, identity: "synthetic") {
            XCTAssertGreaterThan(segment.end, cursor)
            let map = segment.text.coordinates
            for index in 0..<map.length {
                if let point = segment.sourcePoint(NSRange(location: index, length: 1)) {
                    XCTAssertGreaterThanOrEqual(point, segment.text.sourceStart)
                    XCTAssertLessThan(point, segment.end)
                }
            }
            spoken += segment.text.text; cursor = segment.end; segments += 1
            XCTAssertLessThan(segments, 10)
        }
        XCTAssertEqual(spoken.trimmingCharacters(in: .whitespacesAndNewlines), projection.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(spoken.contains("　")); XCTAssertFalse(spoken.contains("\t"))
        XCTAssertEqual(ListeningTextProvider.segment(in: window, at: 109, paragraphStart: true, indent: .smart, identity: nil)?.start, 106)
        let long = String(repeating: "甲😀", count: 700)
        let large = ReadingWindow(chunks: [.init(index: 0, startUtf8: 0, endUtf8: UInt64(long.utf8.count), text: long)], isEndOfBook: true)
        let a = try XCTUnwrap(ListeningTextProvider.segment(in: large, at: 0, paragraphStart: true, indent: .smart, identity: nil))
        let b = try XCTUnwrap(ListeningTextProvider.segment(in: large, at: a.end, paragraphStart: false, indent: .smart, identity: nil))
        XCTAssertLessThanOrEqual(a.text.text.utf16.count, 500)
        XCTAssertEqual(a.end, b.text.sourceStart)
        XCTAssertEqual(a.text.text + b.text.text, String(long.prefix((a.text.text + b.text.text).count)))
        XCTAssertNil(a.sourcePoint(NSRange(location: 5000, length: 1)))
        let emoji = SpeechSegment(text: ReadingText(text: "甲😀 A", sourceStart: 100), contentSHA: nil)
        XCTAssertEqual(emoji.sourceRange(NSRange(location: 1, length: 2)), SourceSpan(startUtf8: 103, endUtf8: 107))
        XCTAssertNil(emoji.sourceRange(NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(emoji.sourceRange(NSRange(location: 0, length: Int.max)))
    }

    func testQueueIsBoundedManualBrowsingDetachesAndReturnDoesNotReplay() async throws {
        let suite = "ListeningTest.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic", forKey: "Moonread.listening.voice")
        let audio = FakeListeningAudio()
        var offset: UInt64 = 0, writes: [UInt64] = [], reads = 0, blocked = false, starts = 0
        let prepared = expectation(description: "current and next queued")
        prepared.expectedFulfillmentCount = 2
        audio.enqueued = { prepared.fulfill() }
        let session = ListeningSession(defaults: defaults, context: {
            ListeningContext(bookID: "fixture", contentSHA: "identity", generation: 1, offset: offset, indent: .smart, title: "Synthetic", chapter: "One")
        }, read: { context, offset, _ in
            reads += 1
            return ListeningRead(segment: SpeechSegment(text: ReadingText(text: "原创😀。", sourceStart: offset), contentSHA: context.contentSHA), atEnd: false)
        }, position: { offset = $0; writes.append($0) }, flush: {}, readabilityChanged: {}, blocked: { blocked }, willStart: { starts += 1 }, voiceAvailable: { _ in true }, audio: { audio })
        session.start()
        await fulfillment(of: [prepared], timeout: 2)
        XCTAssertEqual(reads, 2); XCTAssertEqual(audio.items.count, 2)
        let first = try XCTUnwrap(audio.items.first)
        audio.event?(.began(first.id))
        audio.event?(.range(first.id, NSRange(location: 2, length: 2)))
        session.userNavigated()
        XCTAssertTrue(session.running); XCTAssertEqual(session.following, .detached)
        let queued = audio.items.map(\.id), readsBeforeReturn = reads
        session.tick(uptime: 100)
        XCTAssertEqual(session.safeOffset, 6)
        session.returnToSpeech()
        XCTAssertEqual(session.following, .following)
        XCTAssertEqual(audio.items.map(\.id), queued); XCTAssertEqual(reads, readsBeforeReturn)
        blocked = true; session.checkPresentation(); blocked = false
        XCTAssertEqual(offset, 6, "UTF16 callback maps to original UTF8, not a UTF16 offset")
        XCTAssertEqual(session.phase, .paused)
        XCTAssertTrue(session.ownsPosition, "The still-old screen cannot reclaim the audio location")
        session.userNavigated()
        XCTAssertTrue(session.ownsPosition, "Paused browsing keeps the audio anchor")
        session.end(); session.userNavigated(); offset = 80
        let count = writes.count
        audio.event?(.finished(first.id)); audio.event?(.range(first.id, NSRange(location: 0, length: 1)))
        XCTAssertEqual(writes.count, count); XCTAssertEqual(offset, 80)
        XCTAssertFalse(session.ownsPosition)
        // Listening alone may outlive its own dismissing accessory. A native
        // task above that accessory, or a task without it, still pauses audio.
        let viewport = ReadingViewportAccess(), controller = ReadingController()
        let root = ListeningTestModal(); root.addChild(controller)
        let accessory = ListeningTestModal()
        viewport.controller = controller; root.modal = accessory
        XCTAssertTrue(viewport.hasBlockingPresentation(allowingReaderAccessory: false, allowAccessoryTransitions: true))
        XCTAssertTrue(viewport.hasBlockingPresentation(allowingReaderAccessory: true))
        XCTAssertFalse(viewport.hasBlockingPresentation(allowingReaderAccessory: true, allowAccessoryTransitions: true))
        accessory.modal = UIViewController()
        XCTAssertTrue(viewport.hasBlockingPresentation(allowingReaderAccessory: true, allowAccessoryTransitions: true))
        blocked = true
        session.start()
        XCTAssertFalse(session.running)
        XCTAssertEqual(starts, 1)
        blocked = false
        session.start()
        XCTAssertEqual(starts, 2, "Remote play uses the same mutual-exclusion hook as App play")
        session.end()
        XCTAssertTrue(audio.finished)
    }

    func testInterruptionsTimerAndSourceChangeRequireExplicitContinuation() async throws {
        let suite = "ListeningTest.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic", forKey: "Moonread.listening.voice")
        let audio = FakeListeningAudio()
        var sha = "one", requests = 0, writes = 0, flushes = 0
        let ready = expectation(description: "queued")
        audio.enqueued = { if audio.items.count == 1 { ready.fulfill() } }
        let session = ListeningSession(defaults: defaults, context: {
            ListeningContext(bookID: "fixture", contentSHA: sha, generation: 1, offset: 0, indent: .smart, title: "Synthetic", chapter: "One")
        }, read: { context, offset, _ in
            requests += 1
            return ListeningRead(segment: SpeechSegment(text: ReadingText(text: "原创。", sourceStart: offset), contentSHA: context.contentSHA), atEnd: false)
        }, position: { _ in writes += 1 }, flush: { flushes += 1 }, readabilityChanged: {}, blocked: { false }, voiceAvailable: { _ in true }, audio: { audio })
        session.setTimer(15); session.start()
        await fulfillment(of: [ready], timeout: 2)
        audio.event?(.interrupted)
        XCTAssertEqual(session.phase, .paused)
        let count = requests
        session.tick()
        XCTAssertEqual(requests, count, "An ended interruption never restarts speech")
        let deadline = try XCTUnwrap(session.deadline)
        session.tick(now: deadline)
        XCTAssertEqual(session.phase, .idle, "The deadline still expires while paused")
        XCTAssertTrue(audio.finished)
        // A new source cannot receive callbacks from the former opening.
        audio.enqueued = nil
        session.start()
        let priorWrites = writes, priorFlushes = flushes
        sha = "two"; session.sourceChanged()
        XCTAssertEqual(writes, priorWrites, "Old source coordinates cannot be written to a new identity")
        XCTAssertEqual(flushes, priorFlushes)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.notice)
        session.end()
    }
}

@MainActor private final class FakeListeningAudio: ListeningAudio {
    struct Item { let id: UUID; let text: String }
    var event: ((ListeningAudioEvent) -> Void)?
    var items: [Item] = []
    var enqueued: (() -> Void)?
    var finished = false
    func activate() throws { finished = false }
    func speak(id: UUID, text: String, voice: String, rate: Float) { items.append(Item(id: id, text: text)); enqueued?() }
    func silence() { items.removeAll() }
    func publish(_ metadata: ListeningMetadata, playing: Bool) { }
    func finish() { silence(); finished = true }
}

@MainActor private final class ListeningTestModal: UIViewController {
    var modal: UIViewController?
    override var isBeingDismissed: Bool { true }
    override var presentedViewController: UIViewController? { modal }
}

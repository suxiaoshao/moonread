import AVFoundation
import XCTest
import UIKit
@testable import Moonread

@MainActor final class ListeningTests: ReaderIntegrationFixture {
    func testBoundedSpeechUsesSharedProjectionAndOriginalUTF8Coordinates() throws {
        let raw = "　　原创甲😀，original text。\n\n\t原创乙。\n"
        let firstEnd = UInt64("　　原创甲😀，original text。\n".utf8.count)
        let secondStart = firstEnd + 1, end = UInt64(raw.utf8.count)
        let window = ReadingWindow.preview(chunks: [.init(index: 0, startUtf8: 100, endUtf8: 100 + end, text: raw)], paragraphs: [
            .init(startUtf8: 100, endUtf8: 100 + firstEnd, kind: .body, continuation: false, indented: true),
            .init(startUtf8: 100 + firstEnd, endUtf8: 100 + secondStart, kind: .blank, continuation: false, indented: false),
            .init(startUtf8: 100 + secondStart, endUtf8: 100 + end, kind: .body, continuation: false, indented: true)
        ], trailing: .end)
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
        let large = ReadingWindow.preview(chunks: [.init(index: 0, startUtf8: 0, endUtf8: UInt64(long.utf8.count), text: long)], trailing: .end)
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
        XCTAssertTrue(ListeningVoicesView.matches("中文", name: "Synthetic", language: "zh-CN"))
        XCTAssertTrue(ListeningVoicesView.matches("粤语", name: "Synthetic", language: "yue-HK"))
        XCTAssertTrue(ListeningVoicesView.matches("粵語", name: "Synthetic", language: "yue-HK"))
        XCTAssertTrue(ListeningVoicesView.matches("English", name: "Synthetic", language: "en-US"))
        XCTAssertTrue(ListeningVoicesView.matches("美国", name: "Synthetic", language: "en-US"))
        XCTAssertTrue(ListeningVoicesView.matches("Synthetic", name: "Synthetic", language: "fr-FR"))
        XCTAssertFalse(ListeningVoicesView.matches("中文", name: "Synthetic", language: "fr-FR"))
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
        }, position: { offset = $0; writes.append($0) }, flush: {}, readabilityChanged: {}, admission: { blocked ? .blocked(.externalPresentation) : .allowed }, willStart: { starts += 1 }, voiceAvailable: { _ in true }, audio: { audio })
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

    func testReaderCheckpointsKeepAudioAnchorAcrossBrowsingWindowsAndStop() async throws {
        let (root,service,core,_,_,_,_,suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defaults.set("synthetic",forKey:"Moonread.listening.voice")
        let paragraph = "原创正文，春风照亮前路，夜色温柔。\n"
        let text = "第一章 合成\n" + String(repeating:paragraph,count:8000)
        let file = root.appendingPathComponent("listening.txt"); try text.write(to:file,atomically:true,encoding:.utf8)
        let book = try core.importBook(filePath:file.path,title:"Synthetic")
        let audio = FakeListeningAudio(), queued = expectation(description:"bounded units prepared")
        queued.expectedFulfillmentCount = 2; audio.enqueued = { queued.fulfill() }
        let reader = ReaderSession(service:service,makeListening:{ owner in
            owner.makeListeningSession(defaults:defaults,voiceAvailable:{ _ in true },audio:{ audio })
        })
        await reader.open(.book(book.id)); await awaitState { reader.window != nil }
        reader.coverVisibilityChanged(false)
        let listening = reader.selectListening(); listening.start()
        await fulfillment(of:[queued],timeout:3)
        let first = try XCTUnwrap(audio.items.first)
        audio.event?(.began(first.id)); audio.event?(.range(first.id,NSRange(location:1,length:1)))
        let spoken = try XCTUnwrap(listening.safeOffset)
        let far = book.byteCount - UInt64(paragraph.utf8.count * 2)
        reader.beganReadingInteraction()
        reader.window = ReadingWindow(frame:try await service.frame(book.id,offset:far))
        reader.moved(to:far,settled:true,userInitiated:false)
        listening.tick(uptime:100)
        await reader.flush()
        XCTAssertTrue(listening.running); XCTAssertEqual(listening.following,.detached)
        XCTAssertEqual(reader.anchor,far,"Checkpoint cannot pull a browsed viewport back")
        let saved = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(saved,spoken,"Browse reports never replace the audio position")
        let ids = audio.items.map(\.id)
        let returned = await reader.returnToListening()
        XCTAssertTrue(returned)
        await reader.listeningWindowTask?.value
        XCTAssertEqual(audio.items.map(\.id),ids,"Returning reloads only the reading frame, never speech")
        XCTAssertTrue(try XCTUnwrap(reader.window).start <= spoken && spoken < reader.window!.end)

        let opening = try XCTUnwrap(reader.opening.request?.id)
        let nativeRoot = ListeningTestModal(), controller = ReadingController()
        nativeRoot.addChild(controller); reader.viewportAccess.controller = controller
        let tool = ListeningTestModal(), preview = ListeningTestModal()
        let owner = reader.toolsSession
        let registry = owner.host.nativeLayers
        registry.register(tool, origin: .readerTool(opening: opening, visit: nil))
        registry.register(preview, origin: .readerTool(opening: opening, visit: nil))
        nativeRoot.modal = tool; tool.modal = preview
        owner.sampleNativePresentation()
        listening.tick(uptime: 115)
        XCTAssertTrue(listening.running, "Owned reader tools and their previews must survive a tick")
        XCTAssertEqual(reader.viewportAccess.nativeListeningFacts(registry: registry, opening: UUID(), requestingDock: false), .external)
        preview.modal = UIViewController()
        owner.sampleNativePresentation()
        listening.tick(uptime: 120)
        XCTAssertEqual(listening.phase, .paused, "An unknown native child still blocks")
        preview.modal = nil
        owner.sampleNativePresentation()
        XCTAssertEqual(listening.phase, .paused, "Closing a native task never starts speech")

        reader.stopListening(); await reader.navigationTask?.value
        XCTAssertEqual(reader.anchor,spoken)
        reader.moved(to:far,settled:true,userInitiated:false)
        XCTAssertEqual(reader.anchor,spoken,"A late pre-stop viewport cannot undo the final reveal")
        await reader.flush()
        let stopped = try await service.snapshot(book.id).book.positionUtf8; XCTAssertEqual(stopped,spoken)
        audio.event?(.range(first.id,NSRange(location:0,length:1)))
        await reader.leave().value
        let afterExit = try await service.snapshot(book.id).book.positionUtf8; XCTAssertEqual(afterExit,spoken)
    }

    func testContinueReadingAfterListeningBrowseSavesManualPositionAcrossReopen() async throws {
        let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("synthetic", forKey: "Moonread.listening.voice")
        let target = UInt64("第一章 合成甲\n春风吹过合成的书页。\n".utf8.count)
        let manual = book.byteCount - UInt64("。\n".utf8.count)
        // Chapter jumps and search results share browse(); only search adds a focus range.
        for searchResult in [false, true] {
            let audio = FakeListeningAudio()
            let queued = expectation(description: "speech prepared before browsing")
            audio.enqueued = { if audio.items.count == 1 { queued.fulfill() } }
            let reader = ReaderSession(service: service, makeListening: { owner in
                owner.makeListeningSession(defaults: defaults, voiceAvailable: { _ in true }, audio: { audio })
            })
            await reader.open(.book(book.id))
            await awaitState { reader.window != nil }
            reader.coverVisibilityChanged(false)
            reader.moved(to: 0, settled: true)
            await reader.flush()
            let listening = reader.selectListening()
            listening.start()
            await fulfillment(of: [queued], timeout: 3)
            let first = try XCTUnwrap(audio.items.first)
            audio.event?(.began(first.id))
            audio.event?(.range(first.id, NSRange(location: 1, length: 1)))
            let spoken = try XCTUnwrap(listening.safeOffset)

            reader.browse(to: target, end: searchResult ? target + 3 : nil)
            await reader.navigationTask?.value
            XCTAssertEqual(listening.phase, .paused)
            XCTAssertTrue(listening.ownsPosition, "Unconfirmed browsing retains the audio anchor")
            XCTAssertEqual(reader.anchor, target)
            if searchResult {
                audio.enqueued = nil
                listening.start()
                XCTAssertTrue(listening.running)
                XCTAssertEqual(listening.safeOffset, spoken, "Resume speaks from the audio anchor")
                XCTAssertEqual(listening.following, .detached)
                XCTAssertNotNil(reader.browseOrigin, "Resume preserves the selected reading position")
                XCTAssertEqual(reader.anchor, target)
            }
            await reader.continueReading()
            XCTAssertFalse(listening.ownsPosition, "Explicit continuation hands position back to manual reading")
            XCTAssertNil(reader.browseOrigin)
            XCTAssertNil(reader.focusRange)
            XCTAssertEqual(reader.anchor, target)
            let continued = try await service.snapshot(book.id).book.positionUtf8
            XCTAssertEqual(continued, target, "Continue must immediately save the selected location")

            reader.moved(to: manual, settled: true)
            await reader.saveTask?.value
            // Neither a late speech event nor leaving may restore the old audio anchor.
            audio.event?(.range(first.id, NSRange(location: 0, length: 1)))
            listening.tick(uptime: 100)
            let saved = try await service.snapshot(book.id).book.positionUtf8
            XCTAssertEqual(saved, manual)
            XCTAssertNotEqual(saved, spoken)
            await reader.leave().value
            let reopened = ReaderSession(service: service)
            await reopened.open(.book(book.id))
            await awaitState { reopened.window != nil }
            XCTAssertEqual(reopened.anchor, manual)
            await reopened.leave().value
        }
    }

    func testAcceptSyncedContinuationDuringListeningKeepsLaterManualPositionAcrossReopen() async throws {
        let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("synthetic", forKey: "Moonread.listening.voice")
        let settingsWriting = expectation(description: "settings write holds the old audio flush")
        let gate = SourceReadinessGate(entered: settingsWriting)
        let settingsStore = ReaderSettingsStore(service: service, persist: { _ in await gate.wait() })
        let audio = FakeListeningAudio()
        let queued = expectation(description: "first speech segment ready")
        audio.enqueued = { if audio.items.count == 1 { queued.fulfill() } }
        let reader = ReaderSession(service: service, settingsStore: settingsStore, makeListening: { owner in
            owner.makeListeningSession(defaults: defaults, voiceAvailable: { _ in true }, audio: { audio })
        })
        await reader.open(.book(book.id))
        await awaitState { reader.window != nil }
        reader.coverVisibilityChanged(false)
        let listening = reader.selectListening()
        listening.start()
        await fulfillment(of: [queued], timeout: 3)
        let first = try XCTUnwrap(audio.items.first)
        audio.event?(.began(first.id))
        audio.event?(.range(first.id, NSRange(location: 1, length: 1)))
        let spoken = try XCTUnwrap(listening.safeOffset)
        XCTAssertTrue(listening.ownsPosition)

        let target = UInt64("第一章 合成甲\n春风吹过合成的书页。\n".utf8.count)
        let frame = try await service.frame(book.id, offset: target)
        let accepted = frame.projectionAnchor ?? target
        let manual = book.byteCount - UInt64("。\n".utf8.count)
        reader.presentContinuation(.init(contentSHA: try XCTUnwrap(reader.book?.contentSha256),
            token: "synthetic-continuation", configuration: await service.userCloudConfigurationRevision,
            location: .init(offsetUtf8: target, percentage: 50, chapter: nil)))

        var settings = try XCTUnwrap(reader.settings)
        settings.autoReadingSpeed = settings.autoReadingSpeed == 10 ? 11 : 10
        settingsStore.update(settings)
        await fulfillment(of: [settingsWriting], timeout: 2)
        let flushStarted = expectation(description: "flush captured the audio position before acceptance")
        let staleFlush = Task {
            flushStarted.fulfill()
            await reader.flush()
        }
        await fulfillment(of: [flushStarted], timeout: 2)

        await reader.acceptSyncedContinuation()
        XCTAssertFalse(listening.ownsPosition)
        XCTAssertEqual(listening.phase, .idle)
        XCTAssertNil(reader.continuation)
        XCTAssertEqual(reader.anchor, accepted)
        let adopted = try? await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(adopted, accepted)

        reader.moved(to: manual, settled: true)
        await reader.saveTask?.value
        audio.event?(.range(first.id, NSRange(location: 0, length: 1)))
        await gate.release()
        await staleFlush.value
        let afterFlush = try await service.snapshot(book.id).book.positionUtf8
        XCTAssertEqual(afterFlush, manual)
        XCTAssertNotEqual(afterFlush, spoken)

        await reader.leave().value
        let reopened = ReaderSession(service: service)
        await reopened.open(.book(book.id))
        await awaitState { reopened.window != nil }
        XCTAssertEqual(reopened.anchor, manual)
        await reopened.leave().value
    }

    func testNativeFollowUsesVisiblePagesAndPaintOnlyRanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = ReadingController()
        if UIDevice.current.userInterfaceIdiom == .pad {
            window.frame.size.height = min(window.bounds.height, window.bounds.width * 0.68)
        }
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var text = "", starts: [UInt64] = []
        for index in 0..<160 { starts.append(UInt64(text.utf8.count)); text += "原创第\(index)段，春风轻拂，星光照亮书页。 Original words 😀 continue here.\n" }
        let source = ReadingWindow.preview(chunks: [.init(index: 0, startUtf8: 0, endUtf8: UInt64(text.utf8.count), text: text)], trailing: .end)
        for dark in [false,true] {
            for mode in [ReadingMode.scroll,.pages] {
                var settings = defaultReaderSettings(); settings.mode = mode
                controller.contentGeometry = UIDevice.current.userInterfaceIdiom == .pad ? ReadingContentGeometry(size: controller.view.bounds.size) : nil
                controller.configure(window: source, settings: settings, anchor: 0, dark: dark, typeSize: .large,
                    compactHeaderHeight: 0, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _,_ in })
                controller.guideHeight = 90
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                if let scroll = controller.scrollText {
                    let before = scroll.textStorage.string
                    let unit = SourceSpan(startUtf8: starts[80], endUtf8: starts[80]+3)
                    controller.updateListening(cursor: ListeningCursor(sentence: SourceSpan(startUtf8: starts[80], endUtf8: starts[81]),unit: unit), following: true)
                    XCTAssertGreaterThan(scroll.contentOffset.y, 0)
                    let y = scroll.contentOffset.y
                    controller.updateListening(cursor: ListeningCursor(sentence: SourceSpan(startUtf8: starts[80], endUtf8: starts[81]),unit: SourceSpan(startUtf8: starts[80]+3,endUtf8: starts[80]+6)), following: true)
                    XCTAssertEqual(scroll.contentOffset.y,y,"A visible word does not repeatedly scroll")
                    let layout = try XCTUnwrap(scroll.layoutManager as? ReadingLayoutManager)
                    XCTAssertNotNil(layout.listeningDecoration); XCTAssertEqual(scroll.textStorage.string,before)
                    controller.updateListening(cursor:nil,following:false)
                    XCTAssertNil(layout.listeningDecoration)
                } else {
                    let leaves = controller.currentLeaves
                    if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertEqual(leaves.count,2) }
                    let right = try XCTUnwrap(leaves.last)
                    let positions = leaves.map { $0.page.start }, pageCount = controller.pages.count
                    let offset = right.page.firstVisibleOffset
                    controller.updateListening(cursor:ListeningCursor(sentence:SourceSpan(startUtf8:right.page.start,endUtf8:right.page.end),unit:SourceSpan(startUtf8:offset,endUtf8:offset+3)),following:true)
                    XCTAssertEqual(controller.currentLeaves.map { $0.page.start },positions,"The right visible leaf stays in this spread")
                    let nextIndex = try XCTUnwrap(leaves.map(\.index).max())+1
                    XCTAssertLessThan(nextIndex,controller.pages.count)
                    let next = controller.pages[nextIndex]
                    controller.updateListening(cursor:ListeningCursor(sentence:SourceSpan(startUtf8:next.start,endUtf8:next.end),unit:SourceSpan(startUtf8:next.firstVisibleOffset,endUtf8:next.firstVisibleOffset+3)),following:true)
                    XCTAssertTrue(controller.currentLeaves.contains { $0.page.start == next.start },"Crossing the visible group advances once")
                    XCTAssertEqual(controller.pages.count,pageCount,"Following changes the visible group without repagination")
                }
                let image = UIGraphicsImageRenderer(bounds:controller.view.bounds).image { _ in controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true) }
                let attachment = XCTAttachment(image:image); attachment.name = "listening-\(mode)-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
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
        }, position: { _ in writes += 1 }, flush: { flushes += 1 }, readabilityChanged: {}, admission: { .allowed }, voiceAvailable: { _ in true }, audio: { audio })
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
        let notifications = NotificationCenter()
        let system = SystemListeningAudio(notifications: notifications)
        let reset = expectation(description: "background notification safely crosses to MainActor")
        system.event = { event in
            if case .reset = event { MainActor.preconditionIsolated(); reset.fulfill() }
        }
        await Task.detached {
            notifications.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        }.value
        await fulfillment(of: [reset], timeout: 2)
        system.finish()
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
    var mounting = false
    override var isBeingPresented: Bool { mounting }
    override var isBeingDismissed: Bool { true }
    override var presentedViewController: UIViewController? { modal }
}

import XCTest
import MarkdownView
import Litext
import SwiftUI
import SwiftData
import AISDKProvider
import AISDKProviderUtils
@testable import Moonread

@MainActor private final class AINoticeRecorder {
    var events: [AIActionNotice] = []
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: .aiActionFailed, object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.object as? AIActionNotice else { return }
            MainActor.assumeIsolated { self?.events.append(event) }
        }
    }
    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
}

private final class AIProtocolState: @unchecked Sendable {
    let lock = NSLock()
    var mode = "complete"
    var requestCount = 0
    var stopCount = 0
    private var body: Data?
    func capture(_ request: URLRequest) {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); var result = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
            data = result
        }
        lock.withLock { body = data }
    }
    var requestBody: Data? { lock.withLock { body } }
    func reset(_ value: String) { lock.lock(); defer { lock.unlock() }; mode = value; requestCount = 0; stopCount = 0 }
    func request() -> String { lock.lock(); defer { lock.unlock() }; requestCount += 1; return mode }
    func stopped() { lock.lock(); defer { lock.unlock() }; stopCount += 1 }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (requestCount, stopCount) }
}
private final class AITestURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = AIProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.capture(request)
        let mode = Self.state.request()
        if mode == "headers-wait" { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": ["xai-search", "direct-image", "google-image"].contains(mode) ? "application/json" : "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if mode == "body-wait" { return }
        func event(_ value: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: value)
            var bytes = Data("data: ".utf8); bytes.append(data); bytes.append(Data("\n\n".utf8))
            client?.urlProtocol(self, didLoad: bytes)
        }
        if mode == "google-search" {
            event(["candidates": [["index": 0, "content": ["role": "model", "parts": [["text": "Google answer"]]], "groundingMetadata": ["groundingChunks": [["web": ["uri": "https://example.com/book?signature=A%2FB", "title": "Google title"]], ["web": ["uri": "https://example.com/book?signature=A%2FB", "title": "Later title"]]]], "finishReason": "STOP"]], "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2]])
            client?.urlProtocolDidFinishLoading(self); return
        }
        if mode == "google-image" {
            let value: [String: Any] = ["predictions": [["bytesBase64Encoded": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="]]]
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)); client?.urlProtocolDidFinishLoading(self); return
        }
        if mode == "xai-search" || mode == "direct-image" {
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
            let value: [String: Any] = mode == "direct-image" ? ["data": [["b64_json": png]]] : [
                "output": [["type": "message", "content": [["type": "output_text", "text": "来自检索", "annotations": [["url": "https://example.com/a", "title": "A"]]]]],
                           ["type": "web_search_call", "action": ["sources": [["url": "https://example.com/b", "title": "B"]]]]],
                "citations": ["https://example.com/c"], "usage": ["input_tokens": 20, "output_tokens": 10]]
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self); return
        }
        if request.url?.path.hasSuffix("/chat/completions") == true {
            if mode == "openrouter-replay" {
                event(["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model", "choices": [["index": 0, "delta": ["reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-replay", "id": "r1"]]], "finish_reason": NSNull()]]])
            }
            event(["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model", "choices": [["index": 0, "delta": ["role": "assistant", "content": "你好，**月读**。"], "finish_reason": NSNull()]]])
            event(["id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model", "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]])
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        if request.url?.path.hasSuffix("/messages") == true {
            event(["type": "message_start", "message": ["id": "fixture", "type": "message", "role": "assistant", "model": "fixture-model", "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 1, "output_tokens": 0]]])
            event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "你好，**月读**。"]])
            event(["type": "content_block_stop", "index": 0])
            event(["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 1]])
            event(["type": "message_stop"]); client?.urlProtocolDidFinishLoading(self); return
        }
        if request.url?.path.contains(":streamGenerateContent") == true {
            let parts: [[String: Any]] = mode == "google-inline-image" ? [["inlineData": ["mimeType": "image/png", "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="]]] : [["text": "你好，**月读**。"]]
            event(["candidates": [["content": ["role": "model", "parts": parts], "finishReason": "STOP", "index": 0]], "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2]])
            client?.urlProtocolDidFinishLoading(self); return
        }
        if mode.hasPrefix("native-") {
            event(["type": "response.created", "response": ["id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "in_progress"]])
            if mode == "native-image" {
                let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=")!
                event(["type": "response.output_item.added", "output_index": 0, "item": ["id": "image-call", "type": "image_generation_call", "status": "in_progress"]])
                event(["type": "response.output_item.done", "output_index": 0, "item": ["id": "image-call", "type": "image_generation_call", "status": "completed", "result": data.base64EncodedString()]])
            } else {
                event(["type": "response.output_item.added", "output_index": 0, "item": ["id": "search-call", "type": "web_search_call", "status": "in_progress"]])
                event(["type": "response.output_item.done", "output_index": 0, "item": ["id": "search-call", "type": "web_search_call", "status": "completed", "action": ["type": "search", "query": "novel"]]])
                event(["type": "response.output_item.added", "output_index": 1, "item": ["id": "reply", "type": "message", "role": "assistant", "content": []]])
                event(["type": "response.content_part.added", "item_id": "reply", "output_index": 1, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])
                event(["type": "response.output_text.delta", "item_id": "reply", "output_index": 1, "content_index": 0, "delta": "来源资料"])
                event(["type": "response.output_text.annotation.added", "item_id": "reply", "output_index": 1, "content_index": 0, "annotation_index": 0, "annotation": ["type": "url_citation", "url": "https://example.com/book", "title": "Book source", "start_index": 0, "end_index": 4]])
                event(["type": "response.output_item.done", "output_index": 1, "item": ["id": "reply", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "来源资料", "annotations": []]]]])
            }
            event(["type": "response.completed", "response": ["id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "completed", "usage": ["input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]]])
            client?.urlProtocolDidFinishLoading(self); return
        }
        event(["type": "response.created", "response": ["id": "fixture", "created_at": 1, "model": "fixture-model", "status": "in_progress"]])
        event(["type": "response.output_item.added", "output_index": 0, "item": ["id": "reply", "type": "message", "role": "assistant", "content": []]])
        event(["type": "response.content_part.added", "item_id": "reply", "output_index": 0, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])
        event(["type": "response.output_text.delta", "item_id": "reply", "output_index": 0, "content_index": 0, "delta": "你好，**月读**。"])
        if mode == "text-wait" { return }
        event(["type": "response.output_item.done", "output_index": 0, "item": ["id": "reply", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "你好，**月读**。", "annotations": []]]]])
        event(["type": "response.completed", "response": ["id": "fixture", "created_at": 1, "model": "fixture-model", "status": "completed", "usage": ["input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]]])
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.stopped() }
}
@MainActor final class AIStageOneTests: XCTestCase {
    private func fixture(_ mode: String = "complete", approveSharing: Bool = true) async throws -> (AIService, AIRepository, AIConnection, String) {
        AITestURLProtocol.state.reset(mode)
        let suite = "AIStageOne-\(UUID().uuidString)"
        let repository = try await AIRepository.open(inMemory: true)
        let service = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!, auth: AIAuthentication(credentialResolver: { _ in
            AICredential(accessToken: "test-only", refreshToken: "test-only", expires: Date().addingTimeInterval(600), accountID: "fixture")
        }), makeTransport: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AITestURLProtocol.self]
            return AITransport(configuration: config)
        })
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        if mode == "native-image" { connection.authMethod = .apiKey }
        connection.modelID = "fixture-model"
        connection.models = [AIModelOption(id: "fixture-model", name: "Fixture", contextWindow: 32000, thinking: [], defaultThinking: nil)]
        // Synthetic fixture credential, never read from another software or sent online.
        service.providers.connections = [connection]; service.providers.defaultTextConnectionID = connection.id; await service.load()
        if approveSharing {
            // These pre-existing wire fixtures represent an explicitly consenting user.
            let changed = service.sharing.waitingChanged
            service.sharing.waitingChanged = { owner, waiting in
                changed(owner, waiting)
                if waiting, let request = service.sharing.requests.first(where: { $0.owner == owner }) { service.sharing.answer(request.id, approved: true) }
            }
        }
        return (service, repository, connection, suite)
    }
    private func created(_ service: AIService, context: AIContext = .general, draft: Bool = false) async throws -> AIConversation {
        let value: AIConversation?
        if draft { value = await service.openDraft(context: context) } else { value = await service.create(context: context) }
        return try XCTUnwrap(value)
    }
    private func cleanup(_ connection: AIConnection, suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
        await fulfillment(of: [expectation], timeout: 5)
    }
    func testSharingPreflightRetainsDraftUntilApprovedAndSendsOnlyOnce() async throws {
        let (service, repository, connection, suite) = try await fixture(approveSharing: false)
        defer { cleanup(connection, suite: suite) }
        let value = try await created(service)
        value.draft = "合成共享问题"
        service.send(value.id)
        await wait { !service.sharing.requests.isEmpty }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
        XCTAssertEqual(value.draft, "合成共享问题")
        XCTAssertFalse(value.persisted)
        service.sharing.answer(try XCTUnwrap(service.sharing.requests.first?.id), approved: false)
        await wait { !value.submitting }
        XCTAssertEqual(value.draft, "合成共享问题")
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
        service.send(value.id)
        await wait { !service.sharing.requests.isEmpty }
        service.sharing.answer(try XCTUnwrap(service.sharing.requests.first?.id), approved: true)
        await wait { value.persisted && !value.submitting && !value.running }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
        XCTAssertEqual(value.draft, "")
        let saved = try await repository.session(value.id)
        XCTAssertEqual(saved.id, value.id)
    }

    func testConversationSearchMatchesVisibleMessagesAndOpensHistoryWindows() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        func message(_ role: String, _ text: String, sequence: Int, turn: String) -> AIAgentEntry {
            .init(sequence: sequence, turn: turn, provider: "fixture", model: "fixture",
                  message: .object(["role": .string(role), "content": .object(["value": .string(text)])]),
                  userText: role == "user" ? text : nil, outcome: role == "assistant" ? .completed : nil)
        }
        var long: [AIAgentEntry] = []
        for index in 0..<60 {
            long.append(message("user", index == 3 ? "灯塔在哪里？" : "第\(index)问", sequence: long.count, turn: "t\(index)"))
            long.append(message("assistant", "第\(index)答", sequence: long.count, turn: "t\(index)"))
        }
        try await service.installFixtureSession(AISessionValue(id: "long", title: "长对话"), entries: long)
        // Reasoning, text beside a tool call, unlisted tasks and drafts are not messages to find.
        let parts: JSONValue = .array([.object(["type": .string("reasoning"), "text": .string("推理灯塔")]),
                                       .object(["type": .string("text"), "text": .string("旁白灯塔")]),
                                       .object(["type": .string("tool-call"), "toolCallId": .string("c"), "toolName": .string("search"), "input": .object([:])])])
        try await service.installFixtureSession(AISessionValue(id: "process", title: "过程"), entries: [
            message("user", "普通问题", sequence: 0, turn: "p"),
            .init(sequence: 1, turn: "p", provider: "fixture", model: "fixture", message: .object(["role": .string("assistant"), "content": .object(["parts": parts])]))])
        try await service.installFixtureSession(AISessionValue(id: "task", title: "任务", kind: .statistics, listed: false), entries: [message("user", "灯塔任务", sequence: 0, turn: "k")])
        try await service.installFixtureSession(AISessionValue(id: "titled", title: "灯塔笔记"), entries: [message("user", "无关", sequence: 0, turn: "n")])
        let draft = try await created(service); service.updateDraft(draft.id, text: "灯塔草稿")

        let hits = try await service.searchConversations(" 灯塔 ")
        XCTAssertEqual(Set(hits.map(\.id)), ["long", "titled"])
        let hit = try XCTUnwrap(hits.first { $0.id == "long" })
        XCTAssertTrue(hit.fromUser); XCTAssertEqual(hit.anchor, AIConversationAnchor(sequence: 6, turn: "t3"))
        XCTAssertEqual(hit.snippet, "灯塔在哪里？")
        XCTAssertNil(hits.first { $0.id == "titled" }?.snippet, "A title match keeps the list preview")
        let answer = try await service.searchConversations("第58答")
        XCTAssertEqual(answer.first?.anchor?.sequence, 117); XCTAssertEqual(answer.first?.fromUser, false)

        let conversation = try XCTUnwrap(service.conversation("long"))
        XCTAssertEqual(conversation.entries.first?.sequence, 70, "Opening normally shows the newest page")
        await service.showMessage("long", around: try XCTUnwrap(hit.anchor))
        XCTAssertEqual(conversation.entries.first?.sequence, 0); XCTAssertEqual(conversation.entries.last?.sequence, 56)
        XCTAssertTrue(conversation.hasLater); XCTAssertFalse(conversation.hasEarlier)
        XCTAssertTrue(conversation.turns.contains { $0.id == "t3" })
        service.loadLater("long"); await wait { conversation.entries.last?.sequence == 106 }
        XCTAssertTrue(conversation.hasLater)
        await service.showLatest("long")
        XCTAssertFalse(conversation.hasLater); XCTAssertEqual(conversation.entries.last?.sequence, 119)
        XCTAssertEqual(conversation.entries.first?.sequence, 70)
    }
    func testConversationListThemeRender() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "介绍这篇小说")
        service.send(conversation.id)
        await wait { !conversation.running }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for palette in [try XCTUnwrap(builtinThemePalettes().first { $0.appearance == .light }), try XCTUnwrap(builtinThemePalettes().first { $0.appearance == .dark })] {
            let appearance = palette.appearance
            let theme = ThemeSurface(plan: ResolvedTheme(appearance: appearance, highContrast: false, colors: palette.colors, paletteId: palette.id))
            window.rootViewController = UIHostingController(rootView: AIConversationsView().environment(service).environment(\.theme, theme).preferredColorScheme(theme.scheme))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "conversation-list-\(appearance)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/conversation-list-\(appearance).png"))
        }
    }
    func testGeneralConversationProjectionAndStoredTitleUseFirstMessageWithoutExtraRequest() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service), first = "第一条用户请求"
        service.updateDraft(conversation.id, text: first); service.send(conversation.id)
        await wait { conversation.listed && conversation.title == first && !conversation.partialText.isEmpty }
        let persisted = try await repository.session(conversation.id)
        XCTAssertEqual(persisted.title, first); XCTAssertEqual(conversation.title, first)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1, "Naming does not make an extra provider request")
        service.updateDraft(conversation.id, text: "后续用户请求"); service.send(conversation.id, mode: .followUp)
        await wait { conversation.head.queue.contains { $0.text == "后续用户请求" } }
        let later = try await repository.session(conversation.id)
        XCTAssertEqual(later.title, first); XCTAssertEqual(conversation.title, first)
        service.stop(conversation.id); await wait { !conversation.running }
    }
    func testUnsentConversationsStayInMemoryIncludingSelectionAndAttachments() async throws {
        let (service, repository, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let first = try await created(service, draft: true)
        service.updateDraft(first.id, text: "未发送")
        let attachment = AIReadingAttachment(kind: .book, origin: "test", bookRef: "book:fixture", title: "书籍")
        try await service.addReadingAttachment(first.id, attachment: attachment)
        let selected = await service.applyModelSelection(.init(connectionID: connection.id, modelID: "fixture-model"), to: .session(first.id))
        XCTAssertTrue(selected)
        let second = try await created(service)
        let rows = try await repository.sessions(); XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(first.draft, "未发送"); XCTAssertEqual(first.readingDraft.count, 1)
        XCTAssertFalse(first.persisted); XCTAssertFalse(second.persisted)
        let restarted = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await restarted.load(); XCTAssertTrue(restarted.sessions.isEmpty)
        try await service.deleteSession(first.id)
        XCTAssertNil(service.conversation(first.id))
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    }
    func testSubmissionTaskBlocksRepeatedTapButAllowsSameTextAfterCommit() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let value = try await created(service), text = "相同内容"
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let asset = try await AIImageStore.shared.prepareInput(pixels, owner: value.id)
        try await service.addReadingAttachment(value.id, attachment: .init(kind: .image, origin: "test", title: "图片", attachmentRef: asset.attachment.id), staged: asset)
        service.updateDraft(value.id, text: text)
        service.send(value.id)
        XCTAssertTrue(value.submitting)
        let submission = try XCTUnwrap(value.sendTask)
        service.send(value.id); service.send(value.id, mode: .followUp)
        await submission.value
        XCTAssertFalse(value.submitting); XCTAssertTrue(value.persisted); XCTAssertTrue(value.draft.isEmpty)
        await wait { value.entries.filter { $0.userText == text }.count == 1 && !value.partialText.isEmpty }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
        let stored = try await repository.session(value.id); XCTAssertTrue(stored.listed)
        let storedBytes = try await repository.assetBytes(asset.attachment.id, sessionID: value.id)
        XCTAssertEqual(storedBytes, pixels)
        service.updateDraft(value.id, text: text)
        service.send(value.id, mode: .followUp)
        let next = try XCTUnwrap(value.sendTask); await next.value
        XCTAssertEqual(value.head.queue.filter { $0.text == text }.count, 1)
        service.stop(value.id); await wait { !value.running }
    }
    func testFirstSendFailurePreservesDraftAndAllowsRetry() async throws {
        let notices = AINoticeRecorder(); defer { notices.stop() }
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let value = try await created(service)
        try await service.addReadingAttachment(value.id, attachment: .init(kind: .image, origin: "test", title: "缺失图片", attachmentRef: "missing"))
        service.updateDraft(value.id, text: "重试内容"); service.send(value.id)
        let submission = try XCTUnwrap(value.sendTask); await submission.value
        XCTAssertFalse(value.submitting); XCTAssertFalse(value.persisted)
        XCTAssertEqual(value.draft, "重试内容"); XCTAssertEqual(value.readingDraft.count, 1)
        XCTAssertEqual(notices.events.count, 1)
        XCTAssertEqual(notices.events.first?.sessionID, value.id)
        let rows = try await repository.sessions(); XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
        service.removeReadingAttachment(value.id, attachmentID: value.readingDraft[0].id)
        service.send(value.id); let retry = try XCTUnwrap(value.sendTask); await retry.value
        XCTAssertTrue(value.persisted); XCTAssertFalse(value.submitting); XCTAssertEqual(notices.events.count, 1)
        await wait { !value.partialText.isEmpty }
        service.stop(value.id); await wait { !value.running }
    }
    func testSubmissionLocksTextAttachmentsAndModelUntilCommitted() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let value = try await created(service)
        let attachment = AIReadingAttachment(kind: .book, origin: "test", title: "书籍")
        try await service.addReadingAttachment(value.id, attachment: attachment)
        service.updateDraft(value.id, text: "第一条"); service.send(value.id)
        let submission = try XCTUnwrap(value.sendTask)
        service.updateDraft(value.id, text: "不应写入")
        service.removeReadingAttachment(value.id, attachmentID: value.readingDraft[0].id)
        XCTAssertEqual(value.draft, "第一条"); XCTAssertEqual(value.readingDraft.count, 1)
        // No suspension before the assertions above; async mutation APIs must reject too.
        do { try await service.addReadingAttachment(value.id, attachment: attachment); XCTFail("Submitting attachment edit accepted") } catch {}
        let changed = await service.applyModelSelection(.init(connectionID: connection.id, modelID: "fixture-model"), to: .session(value.id))
        XCTAssertFalse(changed)
        await submission.value
        XCTAssertEqual(value.draft, ""); XCTAssertTrue(value.readingDraft.isEmpty)
        let row = try await repository.session(value.id); XCTAssertTrue(row.listed)
        await wait { value.entries.contains { $0.userText == "第一条" } && !value.partialText.isEmpty }
        service.updateDraft(value.id, text: "下一条草稿")
        try await service.addReadingAttachment(value.id, attachment: attachment)
        XCTAssertEqual(value.draft, "下一条草稿"); XCTAssertEqual(value.readingDraft.count, 1)
        service.stop(value.id); await wait { !value.running }
        let restarted = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await restarted.load()
        let restored = try XCTUnwrap(restarted.conversation(value.id))
        XCTAssertEqual(restored.draft, ""); XCTAssertTrue(restored.readingDraft.isEmpty)
    }
    func testTransferredTaskFollowUpPersistsActivityTimeAcrossReopen() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        var initial = AISessionValue(title: "Task", origin: .init(fileRef: "f:fixture"), kind: .metadata, listed: false)
        initial.updated = Date(timeIntervalSince1970: 1)
        try await service.installFixtureSession(initial, entries: [])
        _ = try await service.transferTask(initial.id)
        let task = try XCTUnwrap(service.conversation(initial.id))
        service.updateDraft(task.id, text: "后续消息"); service.send(task.id, mode: .followUp)
        let submission = try XCTUnwrap(task.sendTask); await submission.value
        let stored = try await repository.session(task.id)
        XCTAssertNotNil(stored.kind); XCTAssertTrue(stored.listed)
        XCTAssertGreaterThan(stored.updated, initial.updated)
        await wait { !task.partialText.isEmpty }
        service.stop(task.id); await wait { !task.running }
        let reopened = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await reopened.load()
        XCTAssertEqual(reopened.conversation(task.id)?.updated, stored.updated)
    }
    func testLoadedHistoryPagesSurviveStreamingNewMessagesAndTerminalUpdates() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let session = AISessionValue(title: "Long conversation")
        let history = try (0..<120).map { sequence in
            AIAgentEntry(sequence: sequence, turn: "old-\(sequence)", provider: "fixture", model: "fixture-model",
                message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("Old message \(sequence)")))), userText: "Old message \(sequence)")
        }
        try await service.installFixtureSession(session, entries: history)
        let value = try XCTUnwrap(service.conversation(session.id))
        XCTAssertEqual(value.entries.count, 50); XCTAssertEqual(value.entries.first?.sequence, 70)
        service.loadEarlier(value.id); await wait { value.entries.count == 100 }
        service.loadEarlier(value.id); service.loadEarlier(value.id)
        await wait { value.entries.count == 120 }
        XCTAssertFalse(value.hasEarlier); XCTAssertEqual(Set(value.entries.map(\.id)).count, 120)
        service.updateDraft(value.id, text: "New message"); service.send(value.id)
        let submission = try XCTUnwrap(value.sendTask); await submission.value
        await wait { !value.partialText.isEmpty && value.entries.contains { $0.userText == "New message" } }
        let oldIDs = history.map(\.id)
        XCTAssertEqual(Array(value.entries.prefix(120)).map(\.id), oldIDs)
        XCTAssertEqual(value.entries.filter { $0.userText == "New message" }.count, 1)
        service.stop(value.id); await wait { !value.running }
        let stored = try await repository.history(value.id, limit: nil)
        XCTAssertEqual(value.entries.map(\.id), stored.map(\.id))
        XCTAssertEqual(value.entries.last?.outcome, .stopped)
        XCTAssertEqual(value.entries.last?.outcome, stored.last?.outcome)
        XCTAssertEqual(Array(value.entries.prefix(120)).map(\.id), oldIDs)
        // A page captured before terminal publication must not restore an old outcome.
        var stale = try XCTUnwrap(value.entries.last); stale.outcome = nil
        value.mergeEntries([stale], updatingExisting: false)
        XCTAssertEqual(value.entries.last?.outcome, .stopped)
    }
    func testOlderResultsAppearOnlyWithTheirLoadedMessagePage() async throws {
        let (service, repository, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let value = AISessionValue(title: "Paged cards")
        let proposal = AIMetadataProposal(proposalRef: "old-result", bookRef: "b:" + String(repeating: "a", count: 64), author: "Old author")
        let output = try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal)))
        let toolEntry = AIAgentEntry(sequence: 1, turn: "old-turn", provider: "fixture", model: "fixture", message: .object([
            "role": .string("tool"), "content": .array([.object(["type": .string("tool-result"), "toolCallId": .string("old-call"), "toolName": .string("propose_book_metadata"), "output": .object(["type": .string("json"), "value": output])])])
        ]))
        var entries = try (0..<80).map { sequence in
            AIAgentEntry(sequence: sequence, turn: "turn-\(sequence)", provider: "fixture", model: "fixture",
                message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("History \(sequence)")))))
        }
        entries[1] = toolEntry
        try await service.installFixtureSession(value, entries: entries)
        let conversation = try XCTUnwrap(service.conversation(value.id))
        XCTAssertEqual(conversation.entries.count, 50); XCTAssertTrue(conversation.turns.flatMap(\.results).isEmpty)
        service.loadEarlier(value.id); await wait { conversation.entries.count == 80 }
        let result = try XCTUnwrap(conversation.turns.flatMap(\.results).first)
        XCTAssertEqual(result.id, toolEntry.id + "/old-call"); XCTAssertEqual(result.sessionID, value.id)
        XCTAssertNil(service.proposals.review(result.id), "Merely loading a message does not restore editable review state")
        let restarted = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await restarted.load()
        let initial = try XCTUnwrap(restarted.conversation(value.id))
        XCTAssertEqual(initial.entries.count, 50); XCTAssertTrue(initial.turns.flatMap(\.results).isEmpty)
    }
    func testTaskEntryDoesNotRequireHistoryResultCounts() {
        let task = AISessionSummary(id: "task", title: "Task", origin: nil, kind: .metadata, listed: false,
            running: false, waitingConfirmation: false, deleting: false)
        XCTAssertEqual(AIQuickTaskStatusRow.text(task, family: .metadata), String(localized: "资料建议"))
        XCTAssertEqual(AIQuickTaskRemoval.message(task), String(localized: "任务及其结果会删除。") + String(localized: "已应用的修改会保留。"))
    }
    func testAllTextProtocolsUseSharedConversationLifecycle() async throws {
        for wire in AIWireProtocol.allCases {
            let (service, _, initial, suite) = try await fixture()
            defer { cleanup(initial, suite: suite) }
            var connection = initial; connection.authMethod = .apiKey
            connection.wireProtocol = wire; connection.baseURL = "https://fixture.invalid/v1"; connection.providerID = "fixture"
            service.providers.connections = [connection]
            let conversation = try await created(service); service.updateDraft(conversation.id, text: "你好")
            service.send(conversation.id)
            await wait { !conversation.running }
            XCTAssertEqual(conversation.turns.last?.outcome, .completed, "\(wire): \(conversation.turns.last?.error ?? "")")
            XCTAssertEqual(conversation.turns.last?.answer, "你好，**月读**。", wire.rawValue)
        }
    }
    func testBundledProviderBrandsAndConnectionPersistence() throws {
        for preset in AIProviderPreset.all {
            let asset = try XCTUnwrap(AIProviderBrand.asset(providerID: preset.id), preset.name)
            XCTAssertNotNil(UIImage(named: asset), "Missing bundled logo: \(preset.name)")
        }
        XCTAssertNil(AIProviderBrand.asset(providerID: "custom-server"))
        let suite = "Moonread.AI.BrandTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        defaults.set(try JSONEncoder().encode([original]), forKey: "Moonread.ai.connections")
        defaults.set(original.id, forKey: "Moonread.ai.defaultTextConnection")
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        XCTAssertEqual(providers.connections.first?.id, original.id)
        let second = providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        providers.saveConnections()
        let restored = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        XCTAssertEqual(restored.connections.count, 2)
        XCTAssertEqual(restored.defaultTextConnectionID, original.id)
        XCTAssertNotEqual(second, original.id)
    }

    func testProviderPresetsAndGatewayRoutes() throws {
        let catalog = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString))
        XCTAssertEqual(Set(AIProviderPreset.all.map(\.identity)).count, AIProviderPreset.all.count)
        for preset in AIProviderPreset.all {
            let connection = preset.connection()
            XCTAssertEqual(connection.baseURL, preset.endpoint)
            XCTAssertEqual(connection.authMethod, preset.auth)
            if preset.auth != .chatGPT && preset.id != "ant-ling" { XCTAssertFalse(catalog.models(for: connection).isEmpty, preset.name) }
            // Ant Ling has no models.dev snapshot; it uses the account /models fallback.
        }
        let gateway = try XCTUnwrap(AIProviderPreset.all.first { $0.id == "opencode-go" }).connection()
        let models = catalog.models(for: gateway)
        XCTAssertEqual(models.first { $0.id == "minimax-m3" }?.wireProtocol, .anthropic)
        XCTAssertEqual(models.first { $0.id == "gpt-6-luna" }?.wireProtocol, .responses)
    }
    func testApprovedProviderAuthenticationSurface() throws {
        XCTAssertEqual(Set(AIProviderPreset.all.map { $0.auth.rawValue }), ["apiKey", "chatGPT", "openrouter"])
        for removed in ["copilot", "kimi", "meta", "xai", "codex"] {
            XCTAssertNil(AIAuthenticationMethod(rawValue: removed))
        }
        XCTAssertFalse(AIProviderPreset.all.contains { $0.id == "github-copilot" })
        XCTAssertNil(AIProviderBrand.asset(providerID: "github-copilot"))
        let catalog = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString))
        XCTAssertNil(catalog.providers["github-copilot"])
        let kimi = AIProviderPreset.all.filter { ["kimi-code-plan-cn", "kimi-code-plan-global"].contains($0.id) }
        XCTAssertEqual(kimi.count, 2)
        XCTAssertTrue(kimi.allSatisfy { $0.auth == .apiKey && $0.billing == .subscription })
        for provider in ["xai", "meta"] {
            XCTAssertTrue(AIProviderPreset.all.filter { $0.id == provider }.allSatisfy { $0.auth == .apiKey })
        }
    }
    func testChatGPTAuthorizationRejectsOtherConnectionMethods() async throws {
        let auth = AIAuthentication()
        for method in [AIAuthenticationMethod.apiKey, .openrouter] {
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
            connection.authMethod = method
            do { _ = try await auth.beginChatGPT(connection); XCTFail("Unexpected SIWC route") }
            catch AIError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    func testRemovingConnectionPreservesHistoryAndOtherAccounts() async throws {
        let notices = AINoticeRecorder(); defer { notices.stop() }
        do { try AIKeychain.remove("test-probe-" + UUID().uuidString) }
        catch { throw XCTSkip("This unsigned host cannot access Keychain; credential deletion requires a signed run.") }
        let (service, repository, connection, suite) = try await fixture("body-wait")
        defer { cleanup(connection, suite: suite) }
        var second = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); second.name = connection.name
        let secondID = service.providers.addConnection(second)
        XCTAssertNotEqual(connection.id, secondID)
        XCTAssertNotEqual(service.providers.connections[0].name, service.providers.connections[1].name)
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "保留这段对话")
        service.send(conversation.id)
        await wait { AITestURLProtocol.state.counts.0 > 0 }
        let removed = await service.removeConnection(connection.id)
        XCTAssertTrue(removed)
        await wait { !conversation.running }
        XCTAssertEqual(service.providers.connections.map(\.id), [secondID])
        XCTAssertNil(service.providers.defaultTextConnectionID)
        let asyncValue1 = (await service.create())?.connectionID
        XCTAssertNil(asyncValue1)
        XCTAssertEqual(service.conversation(conversation.id)?.entries.first?.userText, "保留这段对话")
        let asyncValue2 = try await AIAgentStore(repository: repository).page(conversation.id).first?.userText
        XCTAssertEqual(asyncValue2, "保留这段对话")
        service.updateDraft(conversation.id, text: "不能自动改用其他账户")
        service.send(conversation.id)
        XCTAssertFalse(conversation.running)
        XCTAssertEqual(notices.events.last?.sessionID, conversation.id)
    }
    func testStreamingSaveStopAndSameConversationReopen() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let context = AIContext(contentSHA: "sha-A", title: "甲", chapter: "第一章")
        let conversation = try await created(service, context: context)
        service.updateDraft(conversation.id, text: "解释这段话")
        service.send(conversation.id)
        await wait { !conversation.turns.last!.answer.isEmpty }
        XCTAssertTrue(conversation.running)
        XCTAssertTrue(service.conversation(conversation.id) === conversation)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
        // Reopening observes this exact object and never sends another request.
        XCTAssertTrue(service.conversation(conversation.id) === conversation)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
        service.stop(conversation.id)
        await wait { !conversation.running }
        XCTAssertEqual(conversation.turns.last?.outcome, .stopped)
        XCTAssertEqual(conversation.turns.last?.answer, "你好，**月读**。")
        let reopened = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await reopened.load()
        XCTAssertEqual(reopened.conversation(conversation.id)?.context, context)
        XCTAssertEqual(reopened.conversation(conversation.id)?.turns.last?.outcome, .stopped)
        XCTAssertEqual(reopened.conversation(conversation.id)?.turns.last?.answer, "你好，**月读**。")
    }
    func testBookReentryCreatesNewConversationDespiteRunningSameBookHistory() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let context = AIContext(contentSHA: "same-sha", title: "书籍")
        let old = try await created(service, context: context)
        service.updateDraft(old.id, text: "Old reading conversation"); service.send(old.id)
        await wait { !old.partialText.isEmpty }
        let fresh = try await created(service, context: context)
        XCTAssertNotEqual(old.id, fresh.id); XCTAssertTrue(old.running)
        XCTAssertFalse(fresh.persisted); XCTAssertTrue(fresh.entries.isEmpty)
        let rows = try await repository.sessions(); XCTAssertEqual(rows.map(\.id), [old.id])
        service.stop(old.id); await wait { !old.running }
    }
    func testConversationBeforeModelDirectoryInheritsConnectionDefaults() async throws {
        let (service, _, oldConnection, suite) = try await fixture()
        defer { cleanup(oldConnection, suite: suite) }
        service.providers.connections = []; service.providers.defaultTextConnectionID = nil
        let id = service.providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        let conversation = try await created(service)
        XCTAssertNil(conversation.modelID)
        service.providers.connections[0].models = [AIModelOption(id: "fixture-model", name: "Fixture", contextWindow: 32000, thinking: ["low", "high"], defaultThinking: "low")]
        service.providers.connections[0].modelID = "fixture-model"; service.providers.connections[0].thinking = "high"
        service.providers.saveConnections()
        service.updateDraft(conversation.id, text: "目录就绪后发送"); service.send(conversation.id)
        await wait { conversation.turns.last?.outcome == .completed }
        XCTAssertEqual(conversation.connectionID, id)
        XCTAssertEqual(conversation.modelID, "fixture-model")
        XCTAssertEqual(conversation.turns.last?.thinking, "high")
        // Explicit selections survive a later connection-default change.
        let asyncValue3 = await service.applyModelSelection(.init(connectionID: id, modelID: "fixture-model", thinking: "low"), to: .conversation(conversation.id))
        XCTAssertTrue(asyncValue3)
        service.providers.connections[0].modelID = "different-default"
        service.updateDraft(conversation.id, text: "沿用已选模型"); service.send(conversation.id)
        await wait { conversation.turns.last?.outcome == .completed && conversation.entries.count == 4 }
        XCTAssertEqual(conversation.modelID, "fixture-model")
        XCTAssertEqual(conversation.turns.last?.thinking, "low")
    }
    func testCancellationBeforeHeadersAndDuringSilentBody() async throws {
        for mode in ["headers-wait", "body-wait"] {
            let (service, _, connection, suite) = try await fixture(mode)
            defer { cleanup(connection, suite: suite) }
            let conversation = try await created(service)
            service.updateDraft(conversation.id, text: "等待测试"); service.send(conversation.id)
            await wait { AITestURLProtocol.state.counts.0 == 1 }
            service.stop(conversation.id)
            await wait { !conversation.running }
            XCTAssertEqual(conversation.turns.last?.outcome, .stopped)
            XCTAssertNil(conversation.turns.last?.error)
            XCTAssertGreaterThan(AITestURLProtocol.state.counts.1, 0)
        }
    }
    func testStoppingOneConversationDoesNotStopAnother() async throws {
        let (service, _, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let first = try await created(service), second = try await created(service)
        service.updateDraft(first.id, text: "第一段"); service.send(first.id)
        service.updateDraft(second.id, text: "第二段"); service.send(second.id)
        await wait { first.turns.last?.answer.isEmpty == false && second.turns.last?.answer.isEmpty == false }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 2)
        service.stop(first.id); await wait { !first.running }
        XCTAssertTrue(second.running)
        XCTAssertEqual(second.turns.last?.outcome, .running)
        service.stop(second.id); await wait { !second.running }
    }
    func testCompletedConversationDraftAndRestartInterruption() async throws {
        let (service, repository, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "你好"); service.send(conversation.id)
        await wait { !conversation.running }
        XCTAssertEqual(conversation.turns.last?.outcome, .completed)
        XCTAssertEqual(conversation.head.status, .completed)
        XCTAssertEqual(conversation.turns.last?.answer, "你好，**月读**。")
        service.updateDraft(conversation.id, text: "未发送输入")
        let store = AIAgentStore(repository: repository)
        var unfinished = try await store.head(conversation.id)
        unfinished.status = .running; unfinished.pendingParts = [.init(kind: .text, spanID: "fixture", text: "已收到部分")]
        try await store.commit(conversation.id, head: unfinished)
        let restarted = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await restarted.load()
        let value = try XCTUnwrap(restarted.conversation(conversation.id))
        XCTAssertLessThan(abs(value.updated.timeIntervalSinceNow), 10)
        XCTAssertEqual(value.draft, "")
        XCTAssertTrue(value.readingDraft.isEmpty)
        XCTAssertEqual(value.turns.last?.outcome, .interrupted)
        XCTAssertFalse(value.running)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    }
    func testDeleteRunningConversationDoesNotRecreateMessages() async throws {
        let (service, repository, connection, suite) = try await fixture("text-wait")
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "删除测试"); service.send(conversation.id)
        await wait { !conversation.turns.last!.answer.isEmpty }
        try await service.deleteSession(conversation.id)
        XCTAssertNil(service.conversation(conversation.id))
        do { _ = try await AIAgentStore(repository: repository).page(conversation.id); XCTFail("Deleted owner must not be recreated") } catch {}
        let asyncValue5 = try await repository.sessions().isEmpty
        XCTAssertTrue(asyncValue5)
    }
    func testHostedChatAndSettingsRender() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "你好"); service.send(conversation.id)
        await wait { !conversation.running }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { AIChatView(conversationID: conversation.id) }.environment(service))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "ai-chat-markdown"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension AIStageOneTests {
    func testProtocolFieldsReplayOnlyInOriginalModel() throws {
        let message = AIAgentEntry(sequence: 0, turn: "fixture", provider: "chatgpt", model: "model-A", message: try AIAgentEntry.json(ModelMessage.assistant(.init(content: .parts([
            .reasoning(.init(text: "推理摘要", providerOptions: ["openai": ["reasoningEncryptedContent": .string("fixture-opaque")]])),
            .text(.init(text: "回答"))])))))
        let replay = try message.project(provider: "chatgpt", model: "model-A", tools: true)
        if case .assistant(let assistant) = replay, case .parts(let parts) = assistant.content {
            XCTAssertEqual(parts.count, 2)
            if case .reasoning(let reasoning) = parts[0] { XCTAssertEqual(reasoning.providerOptions?["openai"]?["reasoningEncryptedContent"], .string("fixture-opaque")) }
            else { XCTFail("Expected scoped reasoning") }
        } else { XCTFail("Expected assistant parts") }
        let switched = try message.project(provider: "chatgpt", model: "model-B", tools: true)
        if case .assistant(let assistant) = switched, case .parts(let parts) = assistant.content { XCTAssertEqual(parts.count, 1) }
        else { XCTFail("Expected visible answer only") }
    }
    func testChatGPTDirectoryUsesAccountModelsOnly() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIConnectionTestProtocol.self]
        AIConnectionTestProtocol.state.set("ready")
        let authentication = AIAuthentication(session: URLSession(configuration: config), credentialResolver: { _ in
            AICredential(accessToken: "synthetic-only", refreshToken: "", expires: .distantFuture, accountID: "fixture")
        })
        let models = try await authentication.models(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        XCTAssertEqual(models.map(\.id), ["fixture-model"])
        XCTAssertEqual(models.first?.name, "Fixture Model")
        XCTAssertFalse(models.contains { $0.id == "gpt-6.1-sol" })
    }
}

private final class AIConnectionFixtureState: @unchecked Sendable {
    let lock = NSLock()
    private var value = "ready"
    func set(_ mode: String) { lock.withLock { value = mode } }
    var mode: String { lock.withLock { value } }
}
private final class AIConnectionTestProtocol: URLProtocol, @unchecked Sendable {
    static let state = AIConnectionFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.mode
        if mode == "network" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        var status = 200
        var body: [String: Any]
        if mode == "gemini-pages" || mode == "anthropic-pages" {
            let second = request.url?.query != nil
            if mode == "gemini-pages" {
                body = ["models": [["name": "models/" + (second ? "second" : "first"), "inputTokenLimit": 32000, "outputTokenLimit": 8000]]]
                if !second { body["nextPageToken"] = "next-page" }
            } else {
                body = ["data": [["id": second ? "second" : "first", "max_input_tokens": 32000, "max_tokens": 8000]], "has_more": !second, "last_id": second ? "second" : "first"]
            }
        } else if mode == "models-no-capacity" {
            body = ["data": [["id": "fixture-model", "name": "Refreshed Model"]]]
        } else {
            if mode == "unauthorized" { status = 401 }
            if mode == "models-error" { status = 503 }
            body = ["models": [["id": "fixture-model", "slug": "fixture-model", "visibility": "list", "display_name": "Fixture Model", "context_window": 32000, "default_reasoning_level": "low", "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]]]]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension AIStageOneTests {
    private func connectionFixture() async throws -> (AIService, String, String) {
        AIConnectionTestProtocol.state.set("ready")
        let suite = "AIConnection-\(UUID().uuidString)"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIConnectionTestProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config), credentialSaver: { _, _ in }, credentialResolver: { _ in
            AICredential(accessToken: "fixture", refreshToken: "fixture", expires: Date().addingTimeInterval(600), accountID: "fixture")
        })
        let service = AIService(repository: try await AIRepository.open(inMemory: true), defaults: UserDefaults(suiteName: suite)!, auth: auth)
        return (service, service.providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()), suite)
    }
    func testConnectionModelFailuresDoNotRequireRepeatedAuthorization() async throws {
        let (service, id, suite) = try await connectionFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let unsafeError = NSError(domain: "fixture", code: 9, userInfo: [NSLocalizedDescriptionKey: "private-token-body"])
        XCTAssertFalse(AIConnectionService.connectionError(unsafeError).contains("private-token-body"))
        XCTAssertFalse(AIConnectionService.connectionError(unsafeError).contains("重新登录"))
        await service.providers.refreshModels(id, refreshPublic: false)
        XCTAssertEqual(service.providers.connectionState(service.providers.connections[0]), .connected)
        XCTAssertTrue(service.providers.isLoggedIn(service.providers.connections[0]))
        // Exercise remote API-key catalog errors with a custom endpoint.
        service.providers.connections[0].authMethod = .apiKey
        service.providers.connections[0].providerID = "fixture-custom"
        service.providers.connections[0].baseURL = "https://fixture.invalid/v1"
        let selectedBeforeFailure = service.providers.connections[0].modelID
        AIConnectionTestProtocol.state.set("models-error")
        await service.providers.refreshModels(id, refreshPublic: false)
        guard case .modelsFailed = service.providers.connectionState(service.providers.connections[0]) else { return XCTFail("Expected model-specific failure") }
        XCTAssertTrue(service.providers.isLoggedIn(service.providers.connections[0]))
        XCTAssertEqual(service.providers.connections[0].modelID, selectedBeforeFailure)
        XCTAssertNil(service.providers.loginConnectionID)
        let other = service.providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        XCTAssertEqual(service.providers.connectionState(service.providers.connections.first { $0.id == other }!), .signedOut)
        AIConnectionTestProtocol.state.set("ready"); await service.providers.refreshModels(id, refreshPublic: false)
        XCTAssertEqual(service.providers.connectionState(service.providers.connections[0]), .connected)
        AIConnectionTestProtocol.state.set("unauthorized"); await service.providers.refreshModels(id, refreshPublic: false)
        XCTAssertEqual(service.providers.connectionState(service.providers.connections[0]), .needsLogin)
        XCTAssertFalse(service.providers.isLoggedIn(service.providers.connections[0]))
    }
    func testChatGPTBrowserScopedCancellation() async throws {
        let (service, id, suite) = try await connectionFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let request = AIAuthentication.BrowserAuthorization(id: "fixture", url: URL(string: "https://example.com")!, expires: .distantFuture)
        service.providers.loginConnectionID = id; service.providers.loginStates[id] = .browser(request)
        let other = service.providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        service.providers.login(other); service.providers.cancelLogin(other)
        XCTAssertEqual(service.providers.loginConnectionID, id)
        XCTAssertEqual(service.providers.loginStates[id], .browser(request))
        service.providers.cancelLogin(id)
        XCTAssertEqual(service.providers.connectionState(service.providers.connections[0]), .signedOut)
        XCTAssertNil(service.providers.loginConnectionID)
    }
    func testConnectionSettingsThemeStateScreenshots() async throws {
        let (service, id, suite) = try await connectionFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let palettes = builtinThemePalettes()
        let light = try XCTUnwrap(palettes.first { $0.appearance == .light })
        let dark = try XCTUnwrap(palettes.first { $0.appearance == .dark })
        var custom = light.colors
        custom.canvas = 0xEEE2F7; custom.surface = 0xF8EFFC; custom.ink = 0x3D2852; custom.secondary = 0x665472
        custom.accent = 0x744997; custom.onAccent = 0xFFFFFF
        let themes = [ThemeSurface(plan: ResolvedTheme(appearance: .light, highContrast: false, colors: light.colors, paletteId: light.id)),
                      ThemeSurface(plan: ResolvedTheme(appearance: .dark, highContrast: false, colors: dark.colors, paletteId: dark.id)),
                      ThemeSurface(plan: ResolvedTheme(appearance: .light, highContrast: false, colors: custom, paletteId: "fixture-custom"))]
        for (index, theme) in themes.enumerated() {
            let id = service.providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
            for state in ["signed-out", "code", "connected", "models-error"] {
                service.providers.loginStates[id] = nil; service.providers.modelErrors[id] = nil
                if state != "signed-out" { service.providers.needsLogin.remove(id); await service.providers.refreshModels(id, refreshPublic: false) }
                if state == "code" { service.providers.loginStates[id] = .authorizing }
                if state == "models-error" { service.providers.modelErrors[id] = String(localized: "网络不可用，请稍后重试。") }
                let host = UIHostingController(rootView: NavigationStack { AIConnectionView(connectionID: id) }.environment(service).environment(\.theme, theme).preferredColorScheme(theme.scheme))
                host.overrideUserInterfaceStyle = theme.style; window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(250))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "ai-connection-\(index)-\(state)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}

extension AIStageOneTests {
    func testUnifiedSelectionDraftValidationAndSaveTargets() async throws {
        let (service, repository, first, suite) = try await fixture()
        defer { cleanup(first, suite: suite) }
        service.providers.connections[0].models[0].thinking = ["low", "high"]
        service.providers.connections[0].models[0].defaultThinking = "low"; service.providers.connections[0].thinking = "high"
        var second = first; second.id = "second"; second.name = "Second account"
        second.models[0].thinking = ["medium"]; second.models[0].defaultThinking = "medium"
        service.providers.connections.append(second)
        let conversation = try await created(service)
        let original = try XCTUnwrap(service.modelSelection(for: .conversation(conversation.id)))
        var draft = original
        draft.select(second.models[0], connection: second)
        XCTAssertEqual(draft.connectionID, second.id)
        XCTAssertEqual(draft.thinking, "medium")
        // Cancelling/discarding this draft never writes either save target.
        XCTAssertEqual(service.modelSelection(for: .conversation(conversation.id)), original)
        XCTAssertEqual(service.providers.defaultTextConnectionID, first.id)
        let asyncValue6 = await service.applyModelSelection(draft, to: .conversation(conversation.id))
        XCTAssertTrue(asyncValue6)
        XCTAssertEqual(conversation.connectionID, second.id)
        XCTAssertEqual(conversation.thinking, "medium")
        XCTAssertEqual(service.providers.defaultTextConnectionID, first.id)
        XCTAssertEqual(service.providers.connections[0].thinking, "high")
        let reloaded = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await reloaded.load()
        XCTAssertNil(reloaded.conversation(conversation.id), "Unsent conversations are memory-only")
        let asyncValue7 = await service.applyModelSelection(draft, to: .defaults)
        XCTAssertTrue(asyncValue7)
        XCTAssertEqual(service.providers.defaultTextConnectionID, second.id)
        let settingsReloaded = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(settingsReloaded.providers.defaultTextConnectionID, second.id)
        XCTAssertEqual(settingsReloaded.providers.connections.first { $0.id == second.id }?.thinking, "medium")
        var invalid = draft; invalid.thinking = "unsupported"
        let asyncValue8 = await service.applyModelSelection(invalid, to: .defaults)
        XCTAssertFalse(asyncValue8)
        XCTAssertEqual(service.providers.connections[1].thinking, "medium")
        var noThinking = second.models[0]; noThinking.thinking = []; noThinking.defaultThinking = "invalid"
        noThinking.id = "no-thinking"
        draft.select(noThinking, connection: second)
        XCTAssertNil(draft.thinking)
        var invalidDefault = second.models[0]; invalidDefault.id = "invalid-default"; invalidDefault.defaultThinking = "invalid"
        draft.select(invalidDefault, connection: second)
        XCTAssertNil(draft.thinking, "An invalid declared default must not select an arbitrary effort")
        var validDefault = invalidDefault; validDefault.id = "valid-default"; validDefault.defaultThinking = "medium"
        draft.select(validDefault, connection: second)
        XCTAssertEqual(draft.thinking, "medium")
        for asset in ["ProviderOpenAI", "ProviderAnthropic", "ProviderGoogle", "ProviderXAI"] { XCTAssertNotNil(UIImage(named: asset)) }
    }
    func testRunningModelSelectionAppliesOnlyToNextRequest() async throws {
        let (service, _, first, suite) = try await fixture("text-wait")
        defer { cleanup(first, suite: suite) }
        var next = first; next.id = "next-connection"
        next.models = [AIModelOption(id: "next-model", name: "Next", contextWindow: 32000, thinking: ["high"], defaultThinking: "high")]
        next.modelID = "next-model"; next.thinking = "high"; service.providers.connections.append(next)
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "第一问"); service.send(conversation.id)
        await wait { !conversation.turns.last!.answer.isEmpty }
        let active = conversation.turns.last!
        let stopped = AITestURLProtocol.state.counts.1
        let asyncValue9 = await service.applyModelSelection(AIModelSelection(connectionID: next.id, modelID: next.modelID, thinking: "high"), to: .conversation(conversation.id))
        XCTAssertTrue(asyncValue9)
        XCTAssertTrue(conversation.running)
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
        XCTAssertEqual(AITestURLProtocol.state.counts.1, stopped)
        XCTAssertEqual(conversation.turns.last?.model, active.model)
        XCTAssertEqual(conversation.turns.last?.thinking, active.thinking)
        service.stop(conversation.id); await wait { !conversation.running }
        AITestURLProtocol.state.reset("complete")
        service.updateDraft(conversation.id, text: "第二问"); service.send(conversation.id)
        await wait { conversation.turns.last?.outcome == .completed }
        XCTAssertEqual(conversation.turns.last?.model, "next-model")
        XCTAssertEqual(conversation.turns.last?.thinking, "high")
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    }
    func testUnifiedModelPickerNativeThemesAndEmptyState() async throws {
        let (service, _, first, suite) = try await fixture()
        defer { cleanup(first, suite: suite) }
        service.providers.connections[0].name = "Account A"; service.providers.connections[0].models[0].name = "Same Model"
        service.providers.connections[0].models[0].thinking = ["low", "high"]; service.providers.connections[0].models[0].defaultThinking = "low"
        var second = service.providers.connections[0]; second.id = "second"; second.name = "Account B"
        second.models[0].thinking = []; second.models[0].defaultThinking = nil; service.providers.connections.append(second)
        let conversation = try await created(service); conversation.running = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow); let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey(); conversation.running = false }
        let palettes = builtinThemePalettes()
        let light = try XCTUnwrap(palettes.first { $0.appearance == .light })
        let dark = try XCTUnwrap(palettes.first { $0.appearance == .dark })
        var custom = light.colors; custom.canvas = 0xEEE2F7; custom.surface = 0xF8EFFC; custom.ink = 0x3D2852
        custom.secondary = 0x665472; custom.accent = 0x744997; custom.onAccent = 0xFFFFFF
        let themes: [(String, ThemeSurface)] = [
            ("light", ThemeSurface(plan: ResolvedTheme(appearance: .light, highContrast: false, colors: light.colors, paletteId: light.id))),
            ("dark", ThemeSurface(plan: ResolvedTheme(appearance: .dark, highContrast: false, colors: dark.colors, paletteId: dark.id))),
            ("custom", ThemeSurface(plan: ResolvedTheme(appearance: .light, highContrast: false, colors: custom, paletteId: "fixture-custom")))]
        for (name, theme) in themes {
            let host = UIHostingController(rootView: AIModelPicker(destination: .target(.conversation(conversation.id)), detent: .constant(.large)).environment(service).environment(\.theme, theme).preferredColorScheme(theme.scheme))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "model-picker-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        service.providers.connections = []
        let host = UIHostingController(rootView: AIModelPicker(destination: .target(.defaults), detent: .constant(.large)).environment(service))
        window.rootViewController = host; window.makeKeyAndVisible(); try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "model-picker-empty"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension AIStageOneTests {
    func testPickerEffortDisplaySaveAndRequestAgree() async throws {
        let (service, repository, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        service.providers.connections[0].models[0].thinking = ["low", "high"]
        service.providers.connections[0].models[0].defaultThinking = "low"
        service.providers.connections[0].thinking = "high"
        service.providers.saveConnections()
        let conversation = try await created(service)
        let selection = AIModelSelection(connectionID: connection.id, modelID: "fixture-model", thinking: nil)
        let asyncValue10 = await service.applyModelSelection(selection, to: .conversation(conversation.id))
        XCTAssertTrue(asyncValue10)
        XCTAssertEqual(conversation.thinking, "low")
        XCTAssertEqual(service.modelSelection(for: .conversation(conversation.id))?.thinking, "low")
        let reloaded = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await reloaded.load()
        XCTAssertNil(reloaded.conversation(conversation.id), "Unsent conversations are memory-only")
        service.updateDraft(conversation.id, text: "档位一致性"); service.send(conversation.id)
        await wait { conversation.turns.last?.outcome == .completed }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as? [String: Any])
        XCTAssertEqual((request["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(conversation.turns.last?.thinking, "low")
        let sentReload = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await sentReload.load()
        let sent = try XCTUnwrap(sentReload.conversation(conversation.id))
        XCTAssertEqual(sent.connectionID, connection.id)
        XCTAssertEqual(sent.modelID, request["model"] as? String)
        XCTAssertEqual(sent.thinking, "low")
        XCTAssertEqual(sentReload.modelSelection(for: .conversation(conversation.id))?.thinking, "low")
        XCTAssertEqual(sent.turns.last?.thinking, (request["reasoning"] as? [String: Any])?["effort"] as? String)
        service.providers.connections[0].models[0].thinking = []
        service.providers.saveConnections()
        let asyncValue11 = await service.applyModelSelection(selection, to: .conversation(conversation.id))
        XCTAssertTrue(asyncValue11)
        XCTAssertNil(conversation.thinking)
        XCTAssertNil(service.modelSelection(for: .conversation(conversation.id))?.thinking)
        service.updateDraft(conversation.id, text: "无可调档位"); service.send(conversation.id)
        await wait { conversation.entries.count == 4 && conversation.turns.last?.outcome == .completed }
        let noEffort = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as? [String: Any])
        XCTAssertNil((noEffort["reasoning"] as? [String: Any])?["effort"])
        XCTAssertNil(conversation.turns.last?.thinking)
        XCTAssertEqual(conversation.turns.first?.model, "fixture-model")
        XCTAssertEqual(conversation.turns.first?.thinking, "low", "Changing the next effort never rewrites the first turn")
        let finalReload = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await finalReload.load()
        let final = try XCTUnwrap(finalReload.conversation(conversation.id))
        XCTAssertEqual(final.connectionID, connection.id)
        XCTAssertEqual(final.modelID, noEffort["model"] as? String)
        XCTAssertNil(final.thinking)
        XCTAssertEqual(final.turns.first?.thinking, "low")
        XCTAssertEqual(AIThinkingLabel.label("provider-specific"), "provider-specific")
    }
}

extension AIStageOneTests {
    func testDiscreteThinkingSliderMapsActualLevels() throws {
        XCTAssertEqual(AIThinkingSlider.index(-1, count: 6), 0)
        XCTAssertEqual(AIThinkingSlider.index(9, count: 6), 5)
        XCTAssertEqual(AIThinkingSlider.index(2.6, count: 6), 3)

    }

    func testModelControlsSmallLargeTypeRender() async throws {
        let (service, _, first, suite) = try await fixture()
        defer { cleanup(first, suite: suite) }
        service.providers.connections[0].models[0].thinking = ["none", "minimal", "low", "medium", "high", "xhigh"]
        service.providers.connections[0].thinking = "medium"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        defer { window.isHidden = true; previous?.makeKey() }
        for palette in [try XCTUnwrap(builtinThemePalettes().first { $0.appearance == .light }), try XCTUnwrap(builtinThemePalettes().first { $0.appearance == .dark })] {
            let appearance = palette.appearance
            let theme = ThemeSurface(plan: ResolvedTheme(appearance: appearance, highContrast: false, colors: palette.colors, paletteId: palette.id))
            let root = NavigationStack { AIModelDetailView(connectionID: first.id, modelID: "fixture-model") }
                .environment(service).environment(\.theme, theme).preferredColorScheme(theme.scheme).dynamicTypeSize(.accessibility3)
            window.rootViewController = UIHostingController(rootView: root); window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "model-detail-small-large-type-\(appearance)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

}

extension AIStageOneTests {
    func testCatalogBundleAndProviderSpecificLimits() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let catalog = AIModelCatalog(cacheURL: cacheURL)
        XCTAssertFalse(catalog.providers.isEmpty)
        let model = AIModelOption(id: "gpt-6-astra", name: "Astra", contextWindow: 272000,
                                  thinking: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultThinking: "medium")
        let api = catalog.option(model, providerID: "openai", authentication: .apiKey)
        XCTAssertEqual(api.thinking, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(api.contextWindow, 1050000)
        XCTAssertEqual(api.maxOutput, 128000)
        let subscription = catalog.option(model, providerID: "openai", authentication: .chatGPT)
        XCTAssertEqual(subscription.thinking, model.thinking)
        let account = catalog.resolve(subscription, providerID: "openai", authentication: .chatGPT)
        XCTAssertEqual(account.context, 272000)
        XCTAssertNil(account.output)
        XCTAssertEqual(account.capabilities.imageInput, false)
        XCTAssertEqual(account.capabilities.imageOutput, false)
        var override = model
        override.capabilities = AIModelCapabilities(imageInput: false, tools: false)
        XCTAssertEqual(catalog.resolve(override, providerID: "openai", authentication: .chatGPT).capabilities.imageInput, false)
        let custom = catalog.resolve(model, providerID: "custom", authentication: .apiKey)
        XCTAssertEqual(custom.context, 272000)
        XCTAssertEqual(custom.capabilities.imageInput, false)
    }
}

private final class AICatalogProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var validator: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1; Self.validator = request.value(forHTTPHeaderField: "If-None-Match")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["ETag": "test-catalog"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.status == 200 {
            let body = #"{"openai":{"models":{"fixture":{"modalities":{"input":["text"],"output":["text"]},"reasoning":false,"tool_call":true,"limit":{"context":8192,"output":1024}}}}}"#
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension AIStageOneTests {
    func testManualModelRequiresCapacityAndPreservesIt() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        var connection = AIProviderPreset.all.first { $0.auth == .apiKey }!.connection()
        connection.providerID = "custom"; connection.baseURL = "https://example.com/v1"; connection.models = []
        let id = service.addConnection(connection)
        for values in [("", ""), ("0", ""), ("bad", ""), ("8192", "8193"), ("8192", "-1")] {
            XCTAssertFalse(service.addManualModel(connectionID: id, id: "manual", context: values.0, output: values.1))
        }
        XCTAssertTrue(service.addManualModel(connectionID: id, id: "manual", context: "8192", output: "1024"))
        XCTAssertTrue(service.addManualModel(connectionID: id, id: "manual", context: "8192", output: ""))
        let restored = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        let model = try XCTUnwrap(restored.connections.first?.models.first)
        let resolved = restored.catalog.resolve(model, providerID: "custom", authentication: .apiKey)
        XCTAssertEqual(resolved.context, 8192)
        XCTAssertEqual(resolved.output, 1024)
        XCTAssertTrue(service.addManualModel(connectionID: id, id: "optional-output", context: "8192", output: ""))
    }
    func testDiscoveredCustomModelCapacityOverrideSurvivesRefresh() async throws {
        AIConnectionTestProtocol.state.set("models-no-capacity")
        defer { AIConnectionTestProtocol.state.set("ready") }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIConnectionTestProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config), credentialResolver: { _ in
            .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: "")
        })
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = AIConnectionService(defaults: defaults, auth: auth)
        var connection = AIProviderPreset.all.first { $0.auth == .apiKey }!.connection()
        connection.providerID = "custom"; connection.baseURL = "https://example.com/v1"
        connection.models = [.init(id: "fixture-model", name: "Original", contextWindow: nil, thinking: [])]
        let id = service.addConnection(connection)
        XCTAssertTrue(service.addManualModel(connectionID: id, id: "fixture-model", context: "32000", output: "8000"))
        XCTAssertEqual(service.connections.first?.models.count, 1)
        XCTAssertEqual(service.connections.first?.models.first?.name, "Original")
        await service.refreshModels(id, refreshPublic: false)
        XCTAssertNil(service.modelErrors[id])
        let restored = AIConnectionService(defaults: defaults, auth: auth)
        let model = try XCTUnwrap(restored.connections.first?.models.first)
        XCTAssertEqual(restored.connections.first?.models.count, 1)
        XCTAssertEqual(model.contextWindow, 32000)
        XCTAssertEqual(model.maxOutput, 8000)
        let resolved = restored.catalog.resolve(model, providerID: "custom", authentication: .apiKey)
        XCTAssertEqual(resolved.context, 32000)
        XCTAssertEqual(resolved.output, 8000)
    }
    func testManualRefreshAppliesDownloadedCatalogImmediately() async throws {
        AICatalogProtocol.requests = 0; AICatalogProtocol.status = 200
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AICatalogProtocol.self]
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = Data(#"{"openai":{"models":{"old":{"modalities":{"input":["text"],"output":["text"]},"reasoning":false,"tool_call":true,"limit":{"context":4096}}}}}"#.utf8)
        let catalog = AIModelCatalog(cacheURL: url, session: URLSession(configuration: config), bundled: baseline)
        let auth = AIAuthentication(credentialResolver: { _ in .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: "") })
        let service = AIConnectionService(defaults: UserDefaults(suiteName: UUID().uuidString)!, auth: auth, catalog: catalog)
        var connection = AIProviderPreset.all.first { $0.id == "openai" && $0.auth == .apiKey }!.connection()
        connection.models = catalog.models(for: connection)
        let id = service.addConnection(connection)
        XCTAssertEqual(service.connections.first?.models.first?.id, "old")
        await service.refreshModels(id)
        XCTAssertEqual(AICatalogProtocol.requests, 1)
        XCTAssertEqual(service.connections.first?.models.map(\.id), ["fixture"])
        XCTAssertTrue(service.refreshingModels.isEmpty)
    }
    func testCatalogCacheRefreshAndFailure() async throws {
        AICatalogProtocol.requests = 0; AICatalogProtocol.status = 200
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AICatalogProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = AIModelCatalog(cacheURL: url, session: session, bundled: Data("{}".utf8))
        await catalog.refresh()
        XCTAssertEqual(AICatalogProtocol.requests, 1)
        await catalog.refresh()
        XCTAssertEqual(AICatalogProtocol.requests, 1)
        AICatalogProtocol.status = 304
        await catalog.refresh(force: true)
        XCTAssertEqual(AICatalogProtocol.validator, "test-catalog")
        XCTAssertNotNil(catalog.providers["openai"]?.models["fixture"])
        AICatalogProtocol.status = 500
        await catalog.refresh(force: true)
        XCTAssertNotNil(catalog.providers["openai"]?.models["fixture"])
        let restored = AIModelCatalog(cacheURL: url, session: session, bundled: Data("{}".utf8))
        XCTAssertNotNil(restored.providers["openai"]?.models["fixture"])
        await restored.refresh()
        XCTAssertEqual(AICatalogProtocol.requests, 3)
    }
}

extension AIStageOneTests {
    func testReadingAttachmentsPersistRemovalAndDoNotLeakFixedContext() async throws {
        let (service, repository, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let attachment = AIReadingAttachment(kind: .selection, origin: "reader", bookRef: "b:" + String(repeating: "a", count: 64), title: "附件独有书名", startUtf8: 12, endUtf8: 18, excerpt: "选文")
        let conversation = try await created(service, context: .init(title: "禁止隐含发送的旧上下文"))
        service.seedReadingDraft(conversation.id, attachments: [attachment])
        service.removeReadingAttachment(conversation.id, attachmentID: attachment.id)
        service.seedReadingDraft(conversation.id, attachments: [attachment])
        XCTAssertTrue(conversation.readingDraft.isEmpty)
        let restored = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await restored.load()
        restored.seedReadingDraft(conversation.id, attachments: [attachment])
        XCTAssertNil(restored.conversation(conversation.id))
        service.updateDraft(conversation.id, text: "普通输入")
        service.send(conversation.id)
        await wait { !conversation.running }
        let body = String(decoding: try XCTUnwrap(AITestURLProtocol.state.requestBody), as: UTF8.self)
        XCTAssertFalse(body.contains("禁止隐含发送的旧上下文"))
        XCTAssertFalse(body.contains("附件独有书名"))
        try await service.addReadingAttachment(conversation.id, attachment: attachment)
        let occurrence = try XCTUnwrap(conversation.readingDraft.first)
        XCTAssertNotEqual(occurrence.id, attachment.id)
        var expectedOccurrence = attachment; expectedOccurrence.id = occurrence.id
        XCTAssertEqual(occurrence, expectedOccurrence, "Only the explicit occurrence identity changes")
        service.updateDraft(conversation.id, text: "解释这段")
        service.send(conversation.id)
        await wait { !conversation.running }
        let saved = try await AIAgentStore(repository: repository).page(conversation.id).filter { $0.message.object["role"]?.string == "user" }
        XCTAssertEqual(saved.last?.readingAttachments, [expectedOccurrence], "Persist every field of the independent occurrence")
        let sentReload = AIService(repository: repository, defaults: UserDefaults(suiteName: suite)!)
        await sentReload.load()
        let sent = try XCTUnwrap(sentReload.conversation(conversation.id))
        XCTAssertEqual(sent.entries.filter { $0.message.object["role"]?.string == "user" }.last?.readingAttachments, [expectedOccurrence])
        XCTAssertTrue(saved.first?.readingAttachments.isEmpty == true)
        XCTAssertTrue(conversation.readingDraft.isEmpty)
        let projected = try JSONEncoder().encode(try XCTUnwrap(saved.last).project(provider: "fixture", model: "fixture", tools: true))
        XCTAssertTrue(String(decoding: projected, as: UTF8.self).contains("startUtf8"))
        let attachedBody = String(decoding: try XCTUnwrap(AITestURLProtocol.state.requestBody), as: UTF8.self)
        XCTAssertTrue(attachedBody.contains("附件独有书名"))
        XCTAssertFalse(attachedBody.contains("禁止隐含发送的旧上下文"))
    }
}

extension AIStageOneTests {
    func testReadingAttachmentComposerRenders() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        let items: [AIReadingAttachment] = [
            .init(kind: .position, origin: "reader", bookRef: "b:" + String(repeating: "a", count: 64), title: "云海拾光", chapter: "第一章 小镇的早晨", startUtf8: 1234, endUtf8: 2345, progress: 0.123),
            .init(kind: .selection, origin: "reader", bookRef: "b:" + String(repeating: "a", count: 64), title: "云海拾光", startUtf8: 1300, endUtf8: 1342, excerpt: "清晨的阳光穿过树梢。")
        ]
        service.seedReadingDraft(conversation.id, attachments: items)
        service.updateDraft(conversation.id, text: "这里提到的是谁？")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { AIChatView(conversationID: conversation.id) }.environment(service))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "reading-attachment-composer"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/moonread-attachment-composer.png"))
        XCTAssertEqual(conversation.readingDraft, items)
    }
}

extension AIStageOneTests {
    func testAgentProcessAndFailureRenderWithoutRecoveryButtons() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        let turnID = "render-turn"
        conversation.mergeEntries([
            .init(sequence: 0, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("两人为什么争执？")))), userText: "两人为什么争执？"),
            .init(sequence: 1, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.assistant(.init(content: .parts([
                .text(.init(text: "我先查一下前面的约定。")),
                .toolCall(.init(toolCallId: "read-test", toolName: "read", input: .object([:])))
            ]))))),
            .init(sequence: 2, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.tool(.init(content: [
                .toolResult(.init(toolCallId: "read-test", toolName: "read", output: .json(value: .object(["status": .string("ok"), "data": .object(["text": .string("先确认消息，再一起决定。")])]))))
            ])))),
            .init(sequence: 3, step: 1, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.assistant(.init(content: .text("他们争执的重点是是否遵守约定。")))), outcome: .failed, error: "网络连接中断")
        ])
        conversation.head.currentTurn = turnID; conversation.head.status = .failed; conversation.head.error = "网络连接中断"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { AIChatView(conversationID: conversation.id) }.environment(service))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "agent-process-failure"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/moonread-agent-process.png"))
        XCTAssertEqual(conversation.turns.first?.answer, "他们争执的重点是是否遵守约定。")
        XCTAssertEqual(conversation.turns.first?.process.filter { $0.kind == .tool }.count, 1)
    }
}


extension AIStageOneTests {
    func testToolPresentationAndSourceValidation() throws {
        let result: JSONValue = .object(["data": .object(["kind": .string("bookmark")])])
        XCTAssertEqual(AIToolPresentation.symbol("get_mark", output: result), "bookmark")
        let book = "b:" + String(repeating: "a", count: 64)
        var source: [String: JSONValue] = ["bookRef": .string(book), "range": .object(["startUtf8": .number(3), "endUtf8": .number(12)]), "sourceRef": .string(AIReadingTools.ref("source", "\(book):3:12"))]
        XCTAssertNotNil(AIResultSource(.object(source)))
        source["sourceRef"] = .string("invented")
        XCTAssertNil(AIResultSource(.object(source)))
    }
}

extension AIStageOneTests {
    func testConnectionRequiresExplicitProviderAuthenticationAndProtocol() async throws {
        for preset in AIProviderPreset.all {
            let value = preset.connection()
            let data = try JSONEncoder().encode(value)
            let restored = try JSONDecoder().decode(AIConnection.self, from: data)
            XCTAssertEqual(restored.providerID, preset.id)
            XCTAssertEqual(restored.authMethod, preset.auth)
            XCTAssertEqual(restored.wireProtocol, preset.wire)
            for field in ["providerID", "providerName", "wireProtocol", "authMethod"] {
                var incomplete = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                incomplete.removeValue(forKey: field)
                XCTAssertThrowsError(try JSONDecoder().decode(AIConnection.self, from: JSONSerialization.data(withJSONObject: incomplete)))
            }
        }
    }
}


extension AIStageOneTests {
  func testNativeMarkdownPresentationKeepsHeadingLevelsAndPlainNumberMarkers() {
    let view = AINativeMarkdownView()
    var theme = MarkdownTheme()
    theme.fonts.body = .systemFont(ofSize: 17)
    view.theme = theme
    let text = "# 第一标题\n\n普通段落用于验证窄屏换行后高度增加，标题、列表与段落使用同一份渲染文档。\n\n## 第二标题\n\n### 第三标题\n\n*中文强调* 与 **粗体**。\n\n9. 第一项\n10. 第二项\n    1. 嵌套项"
    view.setContentImmediately(MarkdownContent(markdown: text, theme: theme))
    let document = view.textLabelView.attributedText
    for (heading, size) in [("第一标题", CGFloat(28)), ("第二标题", CGFloat(24)), ("第三标题", CGFloat(20))] {
      let range = (document.string as NSString).range(of: heading)
      XCTAssertNotEqual(range.location, NSNotFound)
      if range.location != NSNotFound { XCTAssertEqual((document.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)?.pointSize, size) }
    }
    var markers: [String] = []
    document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, _, _ in
      XCTAssertNil(attributes[.underlineStyle])
      if let marker = attributes[.litextLineDrawingAction] as? AINativeNumberMarker { markers.append(marker.text) }
    }
    XCTAssertEqual(markers, ["9.", "10.", "1."])
    XCTAssertGreaterThan(view.boundingSize(for: 180).height, view.boundingSize(for: 360).height)
  }

  func testNativeMarkdownTransferredViewSurvivesOldCellReuse() {
    let cache = AINativeMarkdownCache()
    let view = cache.view(id: "retained", text: "接着核对内容。", streaming: false, theme: MarkdownTheme())
    let old = AINativeMarkdownCell(style: .default, reuseIdentifier: "markdown")
    let current = AINativeMarkdownCell(style: .default, reuseIdentifier: "markdown")
    old.frame = CGRect(x: 0, y: 0, width: 180, height: 60)
    current.frame = CGRect(x: 0, y: 0, width: 360, height: 90)
    old.mount(view); old.layoutIfNeeded()
    current.mount(view); current.layoutIfNeeded()
    let expected = view.frame
    old.setNeedsLayout(); old.layoutIfNeeded()
    XCTAssertEqual(view.frame, expected, "A previous cell must not resize a view now mounted elsewhere")
    old.prepareForReuse()
    XCTAssertTrue(view.superview === current.contentView, "Delayed reuse must not detach the current cell's retained view")
    XCTAssertEqual(view.accessibilityLabel, "接着核对内容。")
    XCTAssertFalse(view.isHidden)
    // Reconfiguration of the current cell keeps the same parsed view mounted.
    current.mount(view); current.layoutIfNeeded()
    XCTAssertTrue(view.superview === current.contentView)
    XCTAssertGreaterThan(view.bounds.height, 0)
    // Mounting another block in a stale previous cell must also leave this block alone.
    old.mount(view)
    current.mount(view)
    old.mount(cache.view(id: "other", text: "另一块", streaming: false, theme: MarkdownTheme()))
    XCTAssertTrue(view.superview === current.contentView)
  }

  func testNativeMarkdownRetainsViewsAndBoundsSizingPool() {
    let cache = AINativeMarkdownCache()
    let theme = MarkdownTheme()
    let first = cache.view(id: "block", text: "**第一段", streaming: true, theme: theme)
    XCTAssertTrue(first === cache.view(id: "block", text: "**第一段", streaming: true, theme: theme))
    XCTAssertTrue(first === cache.view(id: "block", text: "**第一段**", streaming: false, theme: theme))
    XCTAssertEqual(first.accessibilityLabel, "第一段")
    let linked = cache.view(id: "link", text: "# 标题\n\n第一段 **重点**。\n\n[示例链接](https://example.com)\n\n最后一段。", streaming: false, theme: theme)
    XCTAssertEqual(linked.accessibilityLabel, "标题\n\n第一段 重点。\n\n示例链接\n\n最后一段。")
    XCTAssertEqual(linked.accessibilityCustomActions?.map(\.name), ["示例链接"])
    let wide = cache.height(id: "block", text: String(repeating: "测量文字", count: 30), streaming: false, theme: theme, width: 360)
    let narrow = cache.height(id: "block", text: String(repeating: "测量文字", count: 30), streaming: false, theme: theme, width: 180)
    XCTAssertGreaterThan(narrow, wide)
    for i in 0..<30 { _ = cache.height(id: "sizing-\(i)", text: "Fixture", streaming: false, theme: theme, width: 320) }
    XCTAssertEqual(cache.sizingCount, 24)
    XCTAssertEqual(cache.retainedCount, 2)
    cache.reset()
    XCTAssertEqual(cache.retainedCount, 0)
    XCTAssertEqual(cache.sizingCount, 0)
  }

}

extension AIStageOneTests {
    func testLightProcessRunningAndCompletedScreens() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        let turnID = "light-process"
        conversation.title = "介绍下这篇小说"
        conversation.mergeEntries([
            .init(sequence: 0, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("介绍下这篇小说，也看看番外讲什么。"))))),
            .init(sequence: 1, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.assistant(.init(content: .parts([
                .reasoning(.init(text: "先核对书籍资料与目录，再结合番外内容给出介绍。")),
                .text(.init(text: "我先看看简介和目录，再读一下番外开头。")),
                .toolCall(.init(toolCallId: "book", toolName: "get_book", input: .object([:]))),
                .toolCall(.init(toolCallId: "chapters", toolName: "get_chapters", input: .object([:])))
            ]))))),
            .init(sequence: 2, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.tool(.init(content: [
                .toolResult(.init(toolCallId: "book", toolName: "get_book", output: .json(value: .object(["status": .string("ok")])))),
                .toolResult(.init(toolCallId: "chapters", toolName: "get_chapters", output: .json(value: .object(["status": .string("ok")]))))
            ]))))
        ])
        conversation.head.currentTurn = turnID; conversation.head.status = .running; conversation.running = true
        conversation.activity = .init(status: .running, reasoning: "目录与正文片段已核对，接下来整理正文和番外的关系。", reasoningActive: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { AIChatView(conversationID: conversation.id) }.environment(service))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for completed in [false, true] {
            if completed {
                conversation.mergeEntries([.init(sequence: 3, step: 1, turn: turnID, provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.assistant(.init(content: .text("正文以两位主角的经历展开，三篇番外补充了人物相处的细节。")))), outcome: .completed)])
                conversation.head.status = .completed; conversation.running = false
            }
            try await Task.sleep(for: .milliseconds(600))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let name = completed ? "light-process-completed" : "light-process-running"
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
        let tools = conversation.turns[0].process.filter { $0.kind == .tool }
        window.rootViewController = UIHostingController(rootView:
            VStack(alignment: .leading, spacing: 6) {
                Text("查询书籍").font(.subheadline.weight(.medium))
                ForEach(tools) { AIProcessRow(item: $0, outcome: .completed, toggle: { _ in }) }
                Text("正文以两位主角的经历展开，番外补充了人物相处的细节。").padding(.top, 10)
                Spacer()
            }.padding(20).themedPage())
        try await Task.sleep(for: .milliseconds(400))
        let compact = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try compact.pngData()?.write(to: URL(fileURLWithPath: "/tmp/compact-process-rows.png"))
        let detail = UIHostingController(rootView: AIToolDetailView(item: try XCTUnwrap(tools.first), outcome: .completed))
        detail.modalPresentationStyle = .pageSheet
        window.rootViewController?.present(detail, animated: false)
        try await Task.sleep(for: .milliseconds(400))
        let sheet = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/compact-process-detail.png"))
        XCTAssertEqual(conversation.turns.first?.outcome, .completed)
        XCTAssertFalse(conversation.turns[0].process.contains(where: \.isRunning))
    }
}


extension AIStageOneTests {

}

private final class AIExpandedAuthProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: [String: Any]
        switch path {
        case "/api/v1/auth/keys":
            body = ["key": "synthetic-router-key"]
        default:
            body = ["access_token": "synthetic-identity", "expires_in": 3600]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension AIStageOneTests {
    func testOpenRouterAuthorizationIsSingleUseAndCancellationIsScoped() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIExpandedAuthProtocol.self]
        let saved = expectation(description: "Router key stored")
        let auth = AIAuthentication(session: URLSession(configuration: config), credentialSaver: { value, _ in
            XCTAssertEqual(value.accessToken, "synthetic-router-key"); saved.fulfill()
        })
        let old = try await auth.beginOpenRouter()
        let current = try await auth.beginOpenRouter()
        await auth.cancelBrowserAuthorization(old.id)
        let query = URLComponents(url: current.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value?.count, 43)
        XCTAssertNil(query.first { $0.name == "callback_url" })
        try await auth.finishOpenRouter(current.id, code: "fixture-code", reference: "fixture")
        await fulfillment(of: [saved], timeout: 1)
        do { try await auth.finishOpenRouter(current.id, code: "fixture-code", reference: "fixture"); XCTFail("Reused verifier") }
        catch AIError.authorizationExpired {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testProviderThinkingUsesServiceSpecificFields() throws {
        for (provider, field) in [("openrouter", "reasoning"), ("ant-ling", "reasoning"), ("togetherai", "reasoning"), ("deepseek", "thinking"), ("alibaba", "enable_thinking")] {
            let connection = try XCTUnwrap(AIProviderPreset.all.first { $0.id == provider && $0.auth == .apiKey }).connection()
            let request = try AIProviderRequest(connection: connection, model: .init(id: "fixture", name: "Fixture", thinking: ["high"]), credential: .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: ""), thinking: "high", conversationID: "fixture", instructions: "fixture", transport: AITransport())
            XCTAssertNotNil(request.options[provider]?[field])
            if ["openrouter", "ant-ling", "togetherai"].contains(provider) { XCTAssertNil(request.options[provider]?["reasoningEffort"]) }
        }
    }
}

extension AIStageOneTests {
    func testReasoningCatalogPreservesBudgetAndGatewayCorrections() throws {
        let catalog = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let old = catalog.option(.init(id: "claude-opus-4-5", name: "Claude", thinking: []), providerID: "anthropic", authentication: .apiKey)
        XCTAssertEqual(old.reasoningParameters?.first { $0.type == "budget_tokens" }?.min, 1024)
        let fixture = Data(#"{"opencode-go":{"models":{"qwen3.5-plus":{"provider":{"npm":"@ai-sdk/anthropic"},"modalities":{"input":["text"],"output":["text"]},"reasoning":true,"tool_call":true,"limit":{"context":32000}}}}}"#.utf8)
        let gateway = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString), bundled: fixture)
        let model = gateway.option(.init(id: "qwen3.5-plus", name: "Qwen", thinking: []), providerID: "opencode-go", authentication: .apiKey)
        XCTAssertEqual(model.wireProtocol, .chat)
    }
    func testBudgetAndEffortReachActualSDKRequests() async throws {
        for (wire, identifier, parameters, expectedKey) in [
            (AIWireProtocol.anthropic, "claude-opus-4-5", [AIReasoningParameter(type: "budget_tokens", min: 1024)], "budget_tokens"),
            (.anthropic, "claude-opus-4-6", [AIReasoningParameter(type: "effort", values: ["high"])], "adaptive"),
            (.gemini, "gemini-2.5-flash", [AIReasoningParameter(type: "budget_tokens", min: 0, max: 24576)], "thinkingBudget"),
            (.gemini, "gemini-3-pro-preview", [AIReasoningParameter(type: "effort", values: ["high"])], "thinkingLevel")
        ] {
            let (service, _, original, suite) = try await fixture()
            defer { cleanup(original, suite: suite) }
            var connection = original
            connection.authMethod = .apiKey; connection.providerID = "fixture"; connection.wireProtocol = wire
            connection.baseURL = "https://fixture.invalid/v1"; connection.modelID = identifier; connection.thinking = "high"
            connection.models = [.init(id: identifier, name: identifier, contextWindow: 128000, thinking: ["high"], defaultThinking: "high", maxOutput: 16000, reasoningParameters: parameters)]
            service.providers.connections = [connection]
            let conversation = try await created(service); service.updateDraft(conversation.id, text: "测试")
            service.send(conversation.id); await wait { !conversation.running }
            XCTAssertEqual(conversation.turns.last?.outcome, .completed, conversation.turns.last?.error ?? identifier)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as? [String: Any])
            if wire == .anthropic {
                XCTAssertEqual(body["max_tokens"] as? Int, 16000)
                let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
                if expectedKey == "adaptive" { XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"]) }
                else { XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 14976) }
            } else {
                let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                XCTAssertEqual(generation["maxOutputTokens"] as? Int, 16000)
                let thinking = try XCTUnwrap(generation["thinkingConfig"] as? [String: Any])
                XCTAssertNotNil(thinking[expectedKey])
        XCTAssertNil(thinking[expectedKey == "thinkingBudget" ? "thinkingLevel" : "thinkingBudget"])
            }
        }
    }
}

@MainActor final class AINativeToolsTests: XCTestCase {
    private var nativeRepository: AIRepository?
    private func fixture(_ mode: String) async throws -> (AIConnectionService, AINativeTools, AIConnection, UserDefaults) {
        AITestURLProtocol.state.reset(mode)
        let defaults = UserDefaults(suiteName: "AINative-\(UUID().uuidString)")!
        let auth = AIAuthentication(credentialResolver: { _ in
            AICredential(accessToken: "test-only", refreshToken: "", expires: Date().addingTimeInterval(600), accountID: "fixture")
        })
        let providers = AIConnectionService(defaults: defaults, auth: auth)
        providers.sharing.waitingChanged = { owner, waiting in
            if waiting, let request = providers.sharing.requests.first(where: { $0.owner == owner }) { providers.sharing.answer(request.id, approved: true) }
        }
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.authMethod = .apiKey
        connection.models = [.init(id: "gpt-6-astra", name: "Astra", contextWindow: 32000, thinking: [])]
        connection.modelID = "gpt-6-astra"
        _ = providers.addConnection(connection)
        for purpose in AIModelPurpose.allCases {
            XCTAssertTrue(providers.setPurpose(purpose, selection: .init(connectionID: connection.id, modelID: connection.modelID)))
        }
        let images = AIImageStore()
        let repository = try await AIRepository.open(inMemory: true)
        try await repository.create(.init(id: "test-session", title: "Native fixture"))
        await images.bind("test-session", repository: repository)
        nativeRepository = repository
        let tools = AINativeTools(providers: providers, owner: "test-session", images: images, makeTransport: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AITestURLProtocol.self]
            return AITransport(configuration: config)
        })
        return (providers, tools, connection, defaults)
    }
    private func commitNative(_ output: AINativeResult, tools: AINativeTools) async throws {
        let refs = Set(output.data.attachments?.map(\.id) ?? [])
        let stage = await tools.images.staged(owner: tools.owner, refs: refs)
        // Test fixture explicitly records the same pending-output first-reference transaction as runtime.
        guard let repository = nativeRepository else { throw AIError.storage }
        var head = try await repository.head(tools.owner)
        head.pendingCalls = [.init(id: "native", name: "generate_image", input: .null, output: try AIAgentEntry.json(output))]
        try await repository.commit(tools.owner, head: head, assets: stage, references: Array(refs))
        await tools.images.didCommit(owner: tools.owner, refs: refs)
    }
    func testPurposeDefaultsPersistWithoutChangingTextModel() async throws {
        let (providers, _, connection, defaults) = try await fixture("native-search")
        let restored = AIConnectionService(defaults: defaults, auth: providers.auth)
        XCTAssertEqual(restored.purposeSelection(.search)?.connectionID, connection.id)
        XCTAssertEqual(restored.purposeSelection(.image)?.modelID, "gpt-6-astra")
        XCTAssertTrue(providers.setPurpose(.search, selection: nil))
        XCTAssertNil(providers.purposeSelection(.search))
        XCTAssertNotNil(providers.purposeSelection(.image))
        XCTAssertEqual(providers.defaultTextConnectionID, connection.id)
    }
    func testToolServiceEligibilityDoesNotRequireLoadedModelsOrDefaultToChatGPT() throws {
        let defaults = UserDefaults(suiteName: "tool-services-\(UUID().uuidString)")!
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        XCTAssertNil(providers.purposeSelection(.search))
        XCTAssertNil(providers.purposeSelection(.image))
        for preset in AIProviderPreset.all {
            var connection = preset.connection()
            connection.models = []
            let expected = connection.authMethod == .chatGPT ||
                (connection.authMethod == .apiKey && ["openai", "google", "xai"].contains(connection.catalogID))
            XCTAssertEqual(AINativeCapabilities.supportsConnection(connection), expected, preset.name)
            connection.baseURL = "https://example.com/v1"
            XCTAssertFalse(AINativeCapabilities.supportsConnection(connection))
        }
        let unknown = AIModelOption(id: "unknown", name: "Unknown", thinking: [])
        XCTAssertEqual(providers.catalog.resolve(unknown, providerID: "openai", authentication: .chatGPT).capabilities.text, false)
    }

    func testNoImplicitCapabilitiesForCustomEndpointOrSubscription() throws {
        var connection = AIProviderPreset.all.first { $0.id == "xai" && $0.auth == .apiKey }!.connection()
        let model = AIModelOption(id: "grok-imagine-image-2.0", name: "Grok Imagine", thinking: [], capabilities: .init(text: false, imageOutput: true))
        XCTAssertTrue(AINativeCapabilities.supports(.image, connection: connection, model: model))
        connection.authMethod = .apiKey; connection.baseURL = "https://example.com/v1"
        XCTAssertFalse(AINativeCapabilities.supports(.image, connection: connection, model: model))
    }
    func testNativeSearchUsesSelectedModelAndReturnsCitations() async throws {
        let (providers, tools, connection, _) = try await fixture("native-search")
        providers.connections[0].models.append(.init(id: "gpt-5", name: "Chat", thinking: []))
        providers.connections[0].modelID = "gpt-5"
        let result = try await tools.search(.init(query: "novel", language: "zh-Hans"))
        XCTAssertEqual(result.data.answer, "来源资料")
        XCTAssertEqual(result.sources.first?.url, "https://example.com/book")
        XCTAssertEqual(result.data.connectionID, connection.id)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
    }
    func testHostedSDKAndXaiSourcesUseCanonicalApplicationIdentity() async throws {
        // Input citations are real provider wire shapes; the SDK creates opaque source IDs itself.
        for (route, mode) in [("chatgpt", "native-search"), ("openai", "native-search"), ("google", "google-search"), ("xai", "xai-search")] {
            let (providers, tools, connection, _) = try await fixture(mode)
            if route == "chatgpt" {
                providers.connections[0].authMethod = .chatGPT
            } else {
                providers.connections[0].authMethod = .apiKey
                providers.connections[0].providerID = route
                providers.connections[0].baseURL = route == "google" ? "https://generativelanguage.googleapis.com/v1beta" : route == "xai" ? "https://api.x.ai/v1" : "https://api.openai.com/v1"
                let id = route == "google" ? "gemini-2.5-flash" : route == "xai" ? "grok-4.7" : "gpt-6-astra"
                providers.connections[0].models = [.init(id: id, name: id, thinking: [])]
                providers.connections[0].wireProtocol = route == "google" ? .gemini : .responses
                XCTAssertTrue(providers.setPurpose(.search, selection: .init(connectionID: connection.id, modelID: id)))
            }
            let result = try await tools.search(.init(query: "book"))
            XCTAssertFalse(result.sources.isEmpty)
            for source in result.sources { XCTAssertTrue(source.isValid)
        XCTAssertEqual(source.sourceRef, AIReadingTools.ref("web", source.url)) }
            if route == "google" {
                XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.title, "Google title")
                XCTAssertEqual(result.sources.first?.url, "https://example.com/book?signature=A%2FB")
            }
            let output = try AIAgentEntry.json(result)
            let entry = AIAgentEntry(sequence: 0, turn: "search", provider: route, model: "fixture", message: .object(["role": .string("tool"), "content": .array([.object(["toolName": .string("web_search"), "output": .object(["value": output])])])]))
            let registry = AIProposalRegistry()
            registry.history = { owner in owner == "owner" ? [entry] : [] }
            let resolved = try await registry.resolveSources(result.sources.map(\.sourceRef), owner: "owner")
            XCTAssertEqual(resolved.map(\.id), result.sources.map(\.sourceRef))
            let asyncValue12 = try await registry.resolveSources(result.sources.map(\.sourceRef), owner: "another-owner").isEmpty
            XCTAssertTrue(asyncValue12)
        }
    }
    func testGeneratedAttachmentPersistsAndIsUsedForEditing() async throws {
        let (_, tools, _, _) = try await fixture("native-image")
        let result = try await tools.generate(.init(prompt: "moon"))
        let attachment = try XCTUnwrap(result.data.attachments?.first)
        try await commitNative(result, tools: tools)
        XCTAssertEqual(attachment.width, 1)
        let reopened = tools.images
        let data = try await reopened.read(owner: "test-session", ref: attachment.id)
        XCTAssertFalse(data.isEmpty)
        let edited = try await tools.generate(.init(prompt: "blue moon", referenceAttachmentRefs: [attachment.id]))
        XCTAssertEqual(edited.data.attachments?.count, 1)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let parts = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let image = try XCTUnwrap(parts.first { $0["type"] as? String == "input_image" })
        XCTAssertTrue((image["image_url"] as? String)?.hasPrefix("data:image/") == true)
        do { _ = try await reopened.read(owner: "another-session", ref: attachment.id); XCTFail("Cross-session reference") } catch { }
        await tools.images.forget("test-session")
        do { _ = try await reopened.read(owner: "test-session", ref: attachment.id); XCTFail("Deleted attachment") } catch { }
    }
    func testMissingOrOtherOwnerImageReferenceFailsExplicitlyBeforeProviderRequest() async throws {
        let (_, tools, _, _) = try await fixture("native-image")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!
        let otherRepository = try await AIRepository.open(inMemory: true)
        try await otherRepository.create(.init(id: "another-session", title: "Other"))
        await tools.images.bind("another-session", repository: otherRepository)
        let other = try await tools.images.save(bytes, owner: "another-session")
        let stage = await tools.images.staged(owner: "another-session", refs: [other.id])
        var otherHead = AIAgentHead(); otherHead.queue = [.init(text: "Sent", mode: .steering, readingAttachments: [.init(kind: .image, origin: "fixture", title: "Image", attachmentRef: other.id)])]
        try await otherRepository.commit("another-session", head: otherHead, assets: stage, references: [other.id])
        defer { Task { await tools.images.forget("another-session") } }
        for ref in [UUID().uuidString, other.attachmentRef] {
            do { _ = try await tools.generate(.init(prompt: "edit", referenceAttachmentRefs: [ref])); XCTFail("Missing reference accepted") }
            catch let error as AIToolError { XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.field, "referenceAttachmentRefs") }
            XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
        }
    }
    func testUnavailableToolIsNotEnabledAndNoRequestIsSent() async throws {
        let (providers, tools, _, _) = try await fixture("native-search")
        providers.setPurpose(.search, selection: nil)
        XCTAssertFalse(tools.definitions()[0].enabled())
        do { _ = try await tools.search(.init(query: "novel")); XCTFail("Unconfigured search") } catch { }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    }
    func testSilentRequestCancellationClosesTransport() async throws {
        let (_, tools, _, _) = try await fixture("headers-wait")
        let task = Task { try await tools.search(.init(query: "novel")) }
        for _ in 0..<100 where AITestURLProtocol.state.counts.0 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {
        let asyncValue13 = error is CancellationError
        XCTAssertTrue(asyncValue13) }
        for _ in 0..<100 where AITestURLProtocol.state.counts.1 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(AITestURLProtocol.state.counts.1, 0)
    }
    func testOpenAIHostedImageRequestShape() async throws {
        let (providers, tools, connection, _) = try await fixture("native-image")
        providers.connections[0].authMethod = .apiKey
        providers.connections[0].baseURL = "https://api.openai.com/v1"
        XCTAssertTrue(providers.setPurpose(.image, selection: .init(connectionID: connection.id, modelID: connection.modelID)))
        _ = try await tools.generate(.init(prompt: "moon"))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "image_generation")
        XCTAssertEqual(tool["output_format"] as? String, "png")
        await tools.images.forget("test-session")
    }
    func testXaiKeyUsesMinimalSearchAndAllCitationLocations() async throws {
        do {
            let (providers, tools, connection, _) = try await fixture("xai-search")
            providers.connections[0].providerID = "xai"; providers.connections[0].authMethod = .apiKey
            providers.connections[0].baseURL = "https://api.x.ai/v1"
            providers.connections[0].models = [.init(id: "grok-4.7", name: "Grok", thinking: [])]
            XCTAssertTrue(providers.setPurpose(.search, selection: .init(connectionID: connection.id, modelID: "grok-4.7")))
            let output = try await tools.search(.init(query: "novel"))
            XCTAssertEqual(output.sources.count, 3)
            XCTAssertEqual(output.data.inputTokens, 20)
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
            XCTAssertEqual(Set(body.keys), ["model", "input", "tools"])
        }
    }
    func testXaiImagesUseDedicatedModelAndSingularPluralEditInputs() async throws {
        do {
            let (providers, tools, connection, _) = try await fixture("direct-image")
            providers.connections[0].providerID = "xai"; providers.connections[0].authMethod = .apiKey
            providers.connections[0].baseURL = "https://api.x.ai/v1"
            let id = "grok-imagine-image-2.0"
            providers.connections[0].models = [.init(id: id, name: id, thinking: [], capabilities: .init(text: false, imageInput: true, imageOutput: true))]
            XCTAssertTrue(providers.setPurpose(.image, selection: .init(connectionID: connection.id, modelID: id)))
            let generated = try await tools.generate(.init(prompt: "moon"))
            try await commitNative(generated, tools: tools)
            let ref = try XCTUnwrap(generated.data.attachments?.first?.attachmentRef)
            for count in [1, 2, 5] {
                _ = try await tools.generate(.init(prompt: "edit", referenceAttachmentRefs: Array(repeating: ref, count: count)))
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
                XCTAssertEqual(body["model"] as? String, id)
                XCTAssertNil(body["tools"])
                if count == 1 { XCTAssertNotNil(body["image"])
        XCTAssertNil(body["images"]) }
                else { XCTAssertNotNil(body["images"])
        XCTAssertEqual(body["aspect_ratio"] as? String, "auto") }
            }
            await tools.images.forget("test-session")
        }
    }
    func testDefaultPurposeSettingsRender() async throws {
        let (_, _, connection, defaults) = try await fixture("native-search")
        let service = AIService(repository: try await AIRepository.open(inMemory: true), defaults: defaults)
        XCTAssertEqual(service.providers.purposeSelection(.search)?.connectionID, connection.id)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { AISettingsView() }.environment(service))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "ai-purpose-settings"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ai-purpose-settings.png"))
        for purpose in AIModelPurpose.allCases {
            window.rootViewController = UIHostingController(rootView: NavigationStack { AIToolServiceView(purpose: purpose) }.environment(service))
            try await Task.sleep(for: .milliseconds(300))
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: screenshot); attachment.name = "ai-service-\(purpose.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            try screenshot.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ai-service-\(purpose.rawValue).png"))
        }
    }
    func testNativeInputSchemaAndImageReferenceValidation() async throws {
        XCTAssertEqual(AIGenerateImageInput.schema.object["properties"]?.object["referenceAttachmentRefs"]?.object["anyOf"]?.array?.first?.object["type"], .string("array"))
        XCTAssertThrowsError(try AIWebSearchInput(query: " ").validate())
        let (_, tools, _, _) = try await fixture("native-image")
        do { _ = try await tools.generate(.init(prompt: "edit", referenceAttachmentRefs: ["../../file"])); XCTFail("Invalid reference") } catch { }
        XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    }
}

@MainActor final class AIProviderContractTests: XCTestCase {
    func testChatGPTAccountDirectoryPreservesOrderingAndVisibility() throws {
        let models = try AIAuthentication.chatGPTModels([
            ["slug": "second", "display_name": "Second", "visibility": "list"],
            ["slug": "hidden", "display_name": "Hidden", "visibility": "hidden"],
            ["slug": "first", "display_name": "First", "visibility": "list"]])
        XCTAssertEqual(models.map(\.id), ["second", "first"])
        XCTAssertEqual(models.map(\.name), ["Second", "First"])
        XCTAssertTrue(models.allSatisfy { $0.capabilities?.imageOutput == false })
        XCTAssertThrowsError(try AIAuthentication.chatGPTModels([["visibility": "list"]]))
    }

    func testDeclaredReasoningControlsAndBudgets() {
        XCTAssertEqual(AIReasoningControl.levels([.init(type: "toggle")]), ["off", "on"])
        XCTAssertEqual(AIReasoningControl.levels([.init(type: "budget_tokens", min: 128, max: 32768)]), ["minimal", "low", "medium", "high"])
        XCTAssertEqual(AIReasoningControl.budget("high", parameter: .init(type: "budget_tokens", max: 32768)), 16384)
        XCTAssertEqual(AIReasoningControl.budget("high", parameter: .init(type: "budget_tokens", max: 8000)), 8000)
        XCTAssertEqual(AIReasoningControl.levels([.init(type: "toggle"), .init(type: "effort", values: ["high", "max"])]), ["off", "high", "max"])
    }
    func testReplayIDsKeepPairsAndItemIdentity() {
        let one = "call|" + String(repeating: "/", count: 100)
        let two = "call|" + String(repeating: "+", count: 100)
        let body: [String: JSONValue] = ["messages": .array([
            .object(["role": .string("assistant"), "tool_calls": .array([.object(["id": .string(one)]), .object(["id": .string(two)])])]),
            .object(["role": .string("tool"), "tool_call_id": .string(one)])])]
        for provider in ["deepseek", "mistral", "openrouter"] {
            let result = AIChatPayload.prepare(body, provider: provider)["messages"]!.array!
            let calls = result[0].object["tool_calls"]!.array!
            XCTAssertEqual(calls[0].object["id"], result[1].object["tool_call_id"])
            XCTAssertNotEqual(calls[0].object["id"], calls[1].object["id"])
            XCTAssertEqual(calls[0].object["id"]!.string!.count, provider == "mistral" ? 9 : 40)
        }
    }
    func testStructuredReasoningRetainsEncryptedAndMergesDeltas() {
        let collector = AIReasoningDetails()
        for detail: JSONValue in [
            .object(["type": .string("reasoning.text"), "text": .string("甲")]),
            .object(["type": .string("reasoning.text"), "text": .string("乙")]),
            .object(["type": .string("reasoning.encrypted"), "data": .string("opaque")])
        ] { collector.accept(.object(["choices": .array([.object(["delta": .object(["reasoning_details": .array([detail])])])])])) }
        let details = collector.metadata()?["openaiCompatible"]?["reasoning_details"]?.array
        XCTAssertEqual(details?.count, 2)
        XCTAssertEqual(details?.first?.object["text"], .string("甲乙"))
        XCTAssertEqual(details?.last?.object["data"], .string("opaque"))
    }
    func testImageModelsAreInCatalogAndNotConversationDefault() {
        let catalog = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let connection = AIProviderPreset.all.first { $0.id == "xai" && $0.auth == .apiKey }!.connection()
        let models = catalog.models(for: connection)
        XCTAssertTrue(models.contains { $0.capabilities?.imageOutput == true })
        XCTAssertTrue(models.contains { $0.capabilities?.text == true })
    }
}

extension AIStageOneTests {
    func testOpenRouterStructuredReasoningSurvivesHistoryAndSecondRequest() async throws {
        let (service, _, original, suite) = try await fixture()
        defer { cleanup(original, suite: suite) }
        var connection = original
        connection.providerID = "openrouter"; connection.authMethod = .apiKey; connection.wireProtocol = .chat
        connection.baseURL = "https://fixture.invalid/v1"
        service.providers.connections = [connection]
        AITestURLProtocol.state.reset("openrouter-replay")
        let conversation = try await created(service)
        service.updateDraft(conversation.id, text: "first"); service.send(conversation.id)
        await wait { !conversation.running }
        service.updateDraft(conversation.id, text: "second"); service.send(conversation.id)
        await wait { !conversation.running }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as! [String: Any]
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let assistant = (body["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "assistant" }
        XCTAssertEqual((assistant?["reasoning_details"] as? [[String: Any]])?.first?["data"] as? String, "opaque-replay")
    }
}

@MainActor extension AINativeToolsTests {
    func testDirectImageRoutesAndGeminiInlineImages() async throws {
        for (provider, modelID, mode, text) in [("openai", "gpt-image-1", "direct-image", false), ("google", "imagen-4.0-generate-001", "google-image", false), ("google", "gemini-2.5-flash-image", "google-inline-image", true)] {
            let (providers, tools, _, _) = try await fixture(mode)
            var connection = AIProviderPreset.all.first { $0.id == provider && $0.auth == .apiKey }!.connection()
            connection.models = [.init(id: modelID, name: modelID, thinking: [], capabilities: .init(text: text, imageInput: true, imageOutput: true))]
            providers.connections = [connection]
            XCTAssertTrue(providers.setPurpose(.image, selection: .init(connectionID: connection.id, modelID: modelID)))
            let result = try await tools.generate(.init(prompt: "cover"))
            XCTAssertEqual(result.data.attachments?.count, 1, provider)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody)) as? [String: Any])
            if text { XCTAssertEqual((body["generationConfig"] as? [String: Any])?["responseModalities"] as? [String], ["TEXT", "IMAGE"])
        XCTAssertNil(body["tools"]) }
            else if provider == "google" { XCTAssertNotNil(body["instances"]) }
            else { XCTAssertEqual(body["model"] as? String, modelID) }
            await tools.images.forget("test-session")
        }
    }
}

extension AIProviderContractTests {
    func testOpenRouterCacheBreakpointsAndAlibabaBudget() throws {
        let body: [String: JSONValue] = ["model": .string("anthropic/claude-sonnet"), "messages": .array([
            .object(["role": .string("system"), "content": .string("instructions")]),
            .object(["role": .string("user"), "content": .string("question")])]), "tools": .array([.object(["type": .string("function")])])]
        let prepared = AIChatPayload.prepare(body, provider: "openrouter")
        for message in prepared["messages"]!.array! {
            XCTAssertEqual(message.object["content"]?.array?.last?.object["cache_control"]?.object["type"], .string("ephemeral"))
        }
        XCTAssertNotNil(prepared["tools"]?.array?.last?.object["cache_control"])
        XCTAssertEqual(AIChatPayload.prepare(body, provider: "deepseek")["tools"], body["tools"])
        let connection = AIProviderPreset.all.first { $0.id == "alibaba" }!.connection()
        let model = AIModelOption(id: "qwen", name: "Qwen", thinking: ["high"], reasoningParameters: [.init(type: "budget_tokens", min: 1, max: 32768)])
        let request = try AIProviderRequest(connection: connection, model: model, credential: .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: ""), thinking: "high", conversationID: "fixture", instructions: "fixture", transport: AITransport())
        XCTAssertEqual(request.options["alibaba"]?["thinking_budget"], .number(16384))
        XCTAssertNil(request.options["alibaba"]?["reasoningEffort"])
    }
}

extension AIProviderContractTests {
    func testUnmappedCatalogControlsDoNotBecomeInventedEfforts() {
        let catalog = AIModelCatalog(cacheURL: URL.temporaryDirectory.appending(path: UUID().uuidString))
        for provider in ["nvidia", "deepinfra", "huggingface", "fireworks-ai"] {
            let connection = AIProviderPreset.all.first { $0.id == provider }!.connection()
            for model in catalog.models(for: connection) {
                XCTAssertFalse(model.thinking.contains("on"), "Unmapped control: \(provider)/\(model.id)")
                if provider == "nvidia" { XCTAssertTrue(model.thinking.isEmpty) }
            }
        }
    }
    func testCrossModelProjectionPreservesPairedToolIDs() throws {
        let id = "call_fixture|item_fixture"
        let call = ModelMessage.assistant(.init(content: .parts([.toolCall(.init(toolCallId: id, toolName: "read", input: .object([:])))])))
        let result = ModelMessage.tool(.init(content: [.toolResult(.init(toolCallId: id, toolName: "read", output: .text(value: "result")))]))
        let a = AIAgentEntry(sequence: 0, turn: "t", provider: "a", model: "a", message: try AIAgentEntry.json(call))
        let b = AIAgentEntry(sequence: 1, turn: "t", provider: "a", model: "a", message: try AIAgentEntry.json(result))
        let projectedA = try AIAgentEntry.json(a.project(provider: "b", model: "b", tools: true))
        let projectedB = try AIAgentEntry.json(b.project(provider: "b", model: "b", tools: true))
        let expected = AIChatPayload.toolID(id, provider: "")
        XCTAssertEqual(projectedA.object["content"]?.object["parts"]?.array?.first?.object["toolCallId"], .string(expected))
        XCTAssertEqual(projectedB.object["content"]?.array?.first?.object["toolCallId"], .string(expected))
    }
}

extension AIProviderContractTests {
    func testCustomDirectoriesFollowTheirProtocol() {
        let google = AIAuthentication.directoryModels([
            ["name": "models/gemini", "displayName": "Gemini", "inputTokenLimit": 123456, "outputTokenLimit": 54321, "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/embed", "supportedGenerationMethods": ["embedContent"]]], wire: .gemini)
        XCTAssertEqual(google.count, 1)
        XCTAssertEqual(google.first?.id, "gemini")
        XCTAssertEqual(google.first?.contextWindow, 123456)
        XCTAssertEqual(google.first?.maxOutput, 54321)
        let chat = AIAuthentication.directoryModels([["id": "model", "name": "Model"], ["slug": "old-codex-shape"]], wire: .chat)
        XCTAssertEqual(chat.map(\.id), ["model"])
        XCTAssertNil(chat.first?.contextWindow)
    }
}

extension AIProviderContractTests {
    func testModelDirectoryPaginationUsesProtocolCursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AIConnectionTestProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: configuration), credentialResolver: { _ in .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: "") })
        for (wire, mode) in [(AIWireProtocol.gemini, "gemini-pages"), (.anthropic, "anthropic-pages")] {
            AIConnectionTestProtocol.state.set(mode)
            var connection = AIProviderPreset.all.first { $0.wire == wire }!.connection()
            connection.authMethod = .apiKey; connection.baseURL = "https://fixture.invalid/v1"
            let models = try await auth.models(connection)
            XCTAssertEqual(models.map(\.id), ["first", "second"])
            XCTAssertEqual(models.last?.maxOutput, 8000)
        }
    }
}


extension AIStageOneTests {
    func testWaitingRowAppearanceScreenshots() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        conversation.head.currentTurn = "waiting-fixture"
        conversation.mergeEntries([.init(sequence: 0, turn: "waiting-fixture", provider: "fixture", model: "fixture",
            message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("介绍这本书，不要剧透。")))), userText: "介绍这本书，不要剧透。")])
        conversation.running = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for dark in [false, true] {
            for large in [false, true] {
                for compacting in [false, true] {
                    conversation.head.status = compacting ? .compacting : .running
                    conversation.activity = .init(status: conversation.head.status)
                    let theme = ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: dark ? .dark : .light, highContrast: false).app)
                    window.rootViewController = UIHostingController(rootView:
                        NavigationStack { AIChatView(conversationID: conversation.id) }
                            .environment(service).environment(\.theme, theme)
                            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                            .preferredColorScheme(dark ? .dark : .light))
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(650))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let name = "waiting-\(dark ? "dark" : "light")-\(large ? "ax" : "normal")-\(compacting ? "compact" : "reply")"
                    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
                }
            }
        }
    }
}

@MainActor private final class AIExpansionFrameProbe: NSObject {
    var samples: [[Double]] = []
    var measure: (() -> [Double])?
    @objc func tick() { if let measure { samples.append(measure()) } }
}

extension AIStageOneTests {
    func testProcessExpansionKeepsClickedRowPositionAcrossFrames() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let theme = ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: .light, highContrast: false).app)
        let appearance = AIMessageListAppearance(theme: theme, typeSize: .large, highlightedTurn: nil)
        var evidence: [String: [[Double]]] = [:]
        for reduced in [false, true] {
          var appearance = appearance; appearance.reduceMotion = reduced
          for reasoning in [false, true] {
            for bottom in [false, true] {
                let controller = AIMessageListController(); controller.conversation = conversation
                window.rootViewController = controller; window.makeKeyAndVisible()
                let item: AIProcessExpansionID = reasoning ? .reasoning("target") : .group("target")
                conversation.processItemExpansion = []
                let block = AIProcessBlock(items: reasoning
                    ? [.init(id: "target", kind: .reasoning, text: String(repeating: "合成思考段落，用于测量展开高度。", count: 20))]
                    : (0..<8).map { .init(id: $0 == 0 ? "target" : "tool-\($0)", kind: .tool, name: "read_book", input: .null, output: .object(["status": .string("ok")])) })
                var revision = 0
                func makeRows() -> [AIMessageRow] {
                    let state = AIProcessExpansionState(group: conversation.processItemExpansion.contains(.group("target")),
                        reasoning: conversation.processItemExpansion.contains(.reasoning("target")) ? ["target"] : [])
                    var rows = (0..<20).map { AIMessageRow(id: "before-\($0)", turnID: nil, content: .error("Synthetic history \($0)")) }
                    rows.append(.init(id: "target", turnID: nil, version: revision, content: .block(block, .completed, state)))
                    if !bottom { rows += (0..<12).map { .init(id: "after-\($0)", turnID: nil, content: .error("Synthetic later \($0)")) } }
                    return rows
                }
                var rows = makeRows()
                var request = AIMessageListRequest(target: bottom ? .bottom : .row("target"))
                func update() {
                    controller.update(rows: rows, render: { id, toggle in
                        if id != "target" { return AnyView(Text(id).frame(height: 70)) }
                        return AnyView(AIMessageRowView(row: rows[20], conversationID: conversation.id, taskObject: nil, preview: { _ in }, loadEarlier: {}, toggleProcessItem: toggle)
                            .environment(service).environment(\.theme, theme))
                    }, background: theme.canvas, bottomInset: 96, request: request, appearance: appearance)
                }
                update(); try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(controller.following, bottom)
                let path = IndexPath(row: 20, section: 0)
                func header(in view: UIView) -> UIView? {
                    if view.accessibilityIdentifier == "aiHeaderGeometry-\(reasoning ? "reasoning" : "group")-target" { return view }
                    return view.subviews.lazy.compactMap { header(in: $0) }.first
                }
                func screenPoint(_ view: UIView, point: CGPoint = .zero) -> CGPoint {
                    var point = point
                    var model: CALayer? = view.layer
                    while let layer = model, layer !== window.layer {
                        let visual = layer.presentation() ?? layer
                        point.x -= visual.bounds.minX + visual.bounds.width * visual.anchorPoint.x
                        point.y -= visual.bounds.minY + visual.bounds.height * visual.anchorPoint.y
                        point = point.applying(visual.affineTransform())
                        point.x += visual.position.x; point.y += visual.position.y
                        model = layer.superlayer
                    }
                    return point
                }
                func measure() -> [Double] {
                    let marker = header(in: controller.tableView)!
                    let cell = controller.tableView.cellForRow(at: path)!
                    let bounds = (cell.layer.presentation() ?? cell.layer).bounds
                    return [CACurrentMediaTime(), controller.tableView.rectForRow(at: path).minY - controller.tableView.contentOffset.y,
                     controller.tableView.contentOffset.y, controller.tableView.contentSize.height,
                     screenPoint(marker).y, marker.convert(.zero, to: window).y,
                     screenPoint(cell, point: CGPoint(x: 0, y: bounds.maxY)).y,
                     controller.tableView.cellForRow(at: IndexPath(row: 19, section: 0)).map { screenPoint($0).y } ?? -1,
                     controller.tableView.cellForRow(at: IndexPath(row: 21, section: 0)).map { screenPoint($0).y } ?? -1]
                }
                for opening in [true, false] {
                    if bottom && !opening {
                        // Reaching the bottom while expanded makes collapse exercise the
                        // normal upper-offset clamp, not only the zero-shortage case.
                        request = .init(target: .bottom); update()
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let before = measure()
                    let beforeHeight = controller.tableView.rectForRow(at: path).height
                    let probe = AIExpansionFrameProbe(); probe.measure = measure; probe.samples = [before]
                    let link = CADisplayLink(target: probe, selector: #selector(AIExpansionFrameProbe.tick))
                    link.add(to: .main, forMode: .common)
                    controller.toggleProcessItem(rowID: "target", item: item)
                    revision += 1; rows = makeRows(); update()
                    try await Task.sleep(for: .milliseconds(400))
                    probe.samples.append(measure()); link.invalidate()
                    XCTAssertFalse(controller.following)
                    let afterHeight = controller.tableView.rectForRow(at: path).height
                    if opening { XCTAssertGreaterThan(afterHeight, beforeHeight + 20) }
                    else { XCTAssertLessThan(afterHeight, beforeHeight - 20) }
                    let table = controller.tableView!
                    let limit = max(-table.adjustedContentInset.top, table.contentSize.height + table.adjustedContentInset.bottom - table.bounds.height)
                    // Earlier self-sized rows can replace estimates during this layout.
                    // The shortage is measured against the offset needed to preserve
                    // this row at its original screen Y, using its final content origin.
                    let requiredOffset = table.rectForRow(at: path).minY - before[1]
                    let shortage = opening ? 0 : max(0, requiredOffset - limit)
                    let expected = before[1] + shortage
                    XCTAssertEqual(probe.samples.last![1], expected, accuracy: 2)
                    if shortage < 0.5 {
                        XCTAssertLessThanOrEqual(probe.samples.map { abs($0[4] - before[4]) }.max()!, 0.5, "Header presentation moved")
                    }
                    let cellError = probe.samples.map { min(abs($0[1] - before[1]), abs($0[1] - expected)) }.max()!
                    XCTAssertLessThanOrEqual(cellError, 2, "Cell moved between allowed anchors")
                    XCTAssertEqual(probe.samples.last![4], before[4] + shortage, accuracy: 0.5)
                    if shortage < 0.5 {
                        XCTAssertLessThanOrEqual(probe.samples.filter { $0[7] >= 0 }.map { abs($0[7] - before[7]) }.max() ?? 0, 0.5, "Previous row moved")
                        for coordinate in [6, 8] {
                            let values = probe.samples.map { $0[coordinate] }.filter { $0 >= 0 }
                            let reversals = zip(values, values.dropFirst()).map { opening ? $0 - $1 : $1 - $0 }
                            XCTAssertLessThanOrEqual(reversals.max() ?? 0, 0.5, "Animation reversed")
                        }
                    }
                    let positions = Set(probe.samples.map { ($0[6] * 10).rounded() })
                    if reduced || shortage > 0.5 { XCTAssertLessThanOrEqual(positions.count, 2) }
                    else { XCTAssertGreaterThan(positions.count, 3, "Expansion should animate rather than jump") }
                    if shortage > 0.5 {
                        XCTAssertLessThanOrEqual(Set(probe.samples.map { ($0[4] * 10).rounded() }).count, 2)
                    }
                    evidence["\(reduced ? "reduced" : "animated")-\(reasoning ? "reasoning" : "group")-\(bottom ? "bottom" : "scrolled")-\(opening ? "open" : "close")"] = probe.samples
                }
            }
        }
        }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "/tmp/ai-expansion-frames.json"))
    }
}

extension AIStageOneTests {
    func testStreamDisplayPreservesGraphemesAndFlushesBoundaries() {
        func row(_ text: String, status: AIAgentStatus = .running, id: String = "text") -> AIMessageRow {
            .init(id: id, turnID: "turn", content: .block(.init(items: [.init(id: id, kind: .text, text: text)]), status))
        }
        let buffer = AIStreamDisplayBuffer()
        buffer.receive([], enabled: true, now: 0)
        let text = "你好👨‍👩‍👧‍👦e\u{301} hello world"
        buffer.receive([row(text)], enabled: true, now: 1)
        for frame in 1...12 {
            buffer.advance(now: 1 + Double(frame) / 60)
            XCTAssertTrue(text.hasPrefix(buffer.displayed))
            XCTAssertEqual(String(Array(text).prefix(buffer.displayed.count)), buffer.displayed)
        }
        XCTAssertEqual(buffer.displayed, text)
        buffer.receive([row(text + "新的增量")], enabled: true, now: 2)
        let tool = AIMessageRow(id: "tool", turnID: "turn", content: .block(.init(items: [.init(id: "tool", kind: .tool)]), .running))
        buffer.receive([row(text + "新的增量"), tool], enabled: true, now: 2.01)
        XCTAssertFalse(buffer.pending)
        XCTAssertEqual(buffer.project([row(text + "新的增量"), tool])[0].nativeText?.text, text + "新的增量")
        buffer.receive([row("结束内容", status: .completed)], enabled: true, now: 3)
        XCTAssertFalse(buffer.pending)
        buffer.reset()
        buffer.receive([row(text)], enabled: true, now: 4)
        XCTAssertEqual(buffer.displayed, text, "Reopened content is immediate")
        buffer.receive([row(text + "减弱动态")], enabled: false, now: 5)
        XCTAssertFalse(buffer.pending)
        buffer.reset(); buffer.receive([], enabled: true, now: 6)
        var previous = ""
        for frame in 0..<120 {
            let now = 6 + Double(frame) / 60
            let authority = String(repeating: "a", count: (frame / 6 + 1) * 30)
            buffer.receive([row(authority)], enabled: true, now: now)
            buffer.advance(now: now)
            XCTAssertTrue(buffer.displayed.hasPrefix(previous), "Displayed progress must never go backwards")
            if frame >= 18 { XCTAssertGreaterThanOrEqual(buffer.displayed.count, (frame / 6 - 2) * 30) }
            previous = buffer.displayed
        }
        buffer.flush(); XCTAssertFalse(buffer.pending)
    }

    func testStreamSmoothingReplay() async throws {
        let (service, _, connection, suite) = try await fixture()
        defer { cleanup(connection, suite: suite) }
        let conversation = try await created(service)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        var evidence: [String: [[Double]]] = [:]
        for dark in [false, true] {
          for reduced in [true, false] {
           for stress in [false, true] {
            conversation.streamDisplay.reset()
            let theme = ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: dark ? .dark : .light, highContrast: false).app)
            let appearance = AIMessageListAppearance(theme: theme, typeSize: .large, highlightedTurn: nil, reduceMotion: reduced)
            let controller = AIMessageListController(); controller.conversation = conversation
            window.rootViewController = controller; window.makeKeyAndVisible()
            var text = String(repeating: "这是一段已有的可见文字，用于检验流式显示时的位置稳定。", count: 30) + "\n\n"
            var version = 0
            var tool = false
            var ended = false
            var phase = 0
            var prefix: [AIMessageRow] = []
            var activeID = "stream"
            var request = AIMessageListRequest(target: .bottom)
            func update() {
                var rows = prefix + [AIMessageRow(id: activeID, turnID: "turn", version: version,
                    content: .block(.init(items: [.init(id: activeID, kind: .text, text: text)]), ended ? .completed : .running))]
                if tool { rows.append(.init(id: "tool", turnID: "turn", content: .block(.init(items: [.init(id: "tool", kind: .tool, name: "read_book")]), .running))) }
                if ended { rows.append(.init(id: "actions", turnID: "turn", content: .actions(text, .completed))) }
                let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                controller.update(rows: rows, render: { id, toggle in
                    AnyView(AIMessageRowView(row: indexed[id]!, conversationID: conversation.id, taskObject: nil,
                        preview: { _ in }, loadEarlier: {}, toggleProcessItem: toggle).environment(service).environment(\.theme, theme))
                }, background: theme.canvas, bottomInset: 160, request: request, appearance: appearance)
            }
            update(); try await Task.sleep(for: .milliseconds(300))
            let caption = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 160, width: window.bounds.width, height: 160))
            caption.backgroundColor = theme.canvas; caption.textColor = theme.ink; caption.textAlignment = .center
            caption.numberOfLines = 0
            caption.text = "合成流回放 · \(dark ? "深色" : "浅色")\n\(reduced ? "立即显示（基线）" : "平滑显示") · \(stress ? "压力场景" : "普通正文")\n输入区上沿"
            window.addSubview(caption)
            defer { caption.removeFromSuperview() }
            let start = CACurrentMediaTime()
            var arrivals: [(Double, Int)] = []
            var lastCPU = 0.0
            let probe = AIExpansionFrameProbe()
            probe.measure = {
                var info = thread_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                _ = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
                let cpu = Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
                let elapsed = CACurrentMediaTime() - start
                let shown = conversation.streamDisplay.pending ? conversation.streamDisplay.displayed.count : text.count
                let lag = arrivals.first(where: { $0.1 > shown }).map { elapsed - $0.0 } ?? 0
                let table = controller.tableView!
                let activePath = IndexPath(row: prefix.count, section: 0)
                let frame = table.rectForRow(at: activePath)
                func markdown(_ root: UIView) -> MarkdownTextView? {
                    if let view = root as? MarkdownTextView { return view }
                    return root.subviews.lazy.compactMap { markdown($0) }.first
                }
                let label = table.cellForRow(at: activePath).flatMap(markdown)?.textLabelView
                let last = label?.layoutLines.last
                let lineRect = last.flatMap { label?.textLayout.viewRect(fromLayoutRect: $0.rect) } ?? .zero
                let y = label?.convert(lineRect, to: window).minY ?? -1
                defer { lastCPU = cpu }
                let viewport = table.bounds.height - table.adjustedContentInset.top - table.adjustedContentInset.bottom
                let lines = label?.layoutLines.flatMap { line -> [Double] in
                    let rect = label!.convert(label!.textLayout.viewRect(fromLayoutRect: line.rect), to: window)
                    return [Double(line.stringRange.location), rect.minY, rect.height]
                } ?? []
                return [elapsed, table.contentOffset.y, table.contentSize.height, frame.minY - table.contentOffset.y,
                        Double(shown), Double(text.count), lag, lastCPU == 0 ? 0 : (cpu-lastCPU)*1000, y, Double(last?.stringRange.location ?? 0), controller.bottomGap, viewport, Double(phase), Double(prefix.count)] + lines
            }
            let link = CADisplayLink(target: probe, selector: #selector(AIExpansionFrameProbe.tick))
            link.add(to: .main, forMode: .common)
            let chunks = ["新的一行文字，连续显示，不应整行突然跳动。👨‍👩‍👧‍👦\n", "- 列表项目第一项，说明内容。\n- 列表第二项。\n", "\n```swift\nlet message = \"Hello world\"\nprint(message)\n```\n", "\n| 项目 | 结果 |\n| --- | --- |\n| 第一项 | 完成 |\n", String(repeating: "连续文字检验显示进度。", count: 6)]
            for index in 0..<20 {
                if index == 10 && stress {
                    tool = true; update()
                    XCTAssertFalse(conversation.streamDisplay.pending)
                    let preceding: [AIMessageRow] = [
                        .init(id: activeID, turnID: "turn", version: version, content: .block(.init(items: [.init(id: activeID, kind: .text, text: text)]), .running)),
                        .init(id: "tool", turnID: "turn", content: .block(.init(items: [.init(id: "tool", kind: .tool, name: "read_book")]), .running))
                    ]
                    try await Task.sleep(for: .milliseconds(100))
                    prefix = preceding; activeID = "stream-next"; text = ""; arrivals = []; tool = false
                }
                text += stress ? chunks[index % chunks.count] : (index == 8 ? "\n- 简短列表。\n" : index == 15 ? "\n`短代码`。\n" : "模型正在平稳输出正文。"); version += 1
                arrivals.append((CACurrentMediaTime() - start, text.count)); update()
                try await Task.sleep(for: .milliseconds(100))
            }
            phase = 1; ended = true; update()
            XCTAssertFalse(conversation.streamDisplay.pending, "Completion flushes the final text")
            try await Task.sleep(for: .milliseconds(700))
            phase = 2
            request = .init(target: .preserve); update()
            controller.tableView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
            controller.scrollViewWillBeginDragging(controller.tableView)
            let offset = controller.tableView.contentOffset.y
            prefix.append(.init(id: activeID, turnID: "turn", version: version,
                content: .block(.init(items: [.init(id: activeID, kind: .text, text: text)]), .completed)))
            prefix.append(.init(id: "actions", turnID: "turn", content: .actions(text, .completed)))
            activeID = "next-turn"; text = ""; arrivals = []; ended = false; tool = false
            for _ in 0..<5 { text += chunks[0]; version += 1; update(); try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertEqual(controller.tableView.contentOffset.y, offset, accuracy: 2)
            phase = 3; conversation.streamDisplay.flush(); update()
            XCTAssertFalse(conversation.streamDisplay.pending)
            link.invalidate()
            let key = "\(dark ? "dark" : "light")-\(reduced ? "baseline" : "smooth")-\(stress ? "stress" : "normal")"
            evidence[key] = probe.samples
            XCTAssertLessThanOrEqual(probe.samples.map { $0[6] }.max() ?? 0, 0.3)
            if !reduced {
                let followed = probe.samples.filter { $0[12] < 2 }
                let lineHeight = appearance.markdownTheme(traits: controller.traitCollection).fonts.body.lineHeight
                for (a, b) in zip(followed, followed.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b[1] - a[1], -0.5, "No reverse scrolling")
                    XCTAssertLessThanOrEqual(b[1] - a[1], stress || b[12] == 1 ? b[11] / 8 : lineHeight / 3 + 0.34)
                }
                XCTAssertLessThanOrEqual(followed.map { $0[10] / $0[11] }.max() ?? 0, 0.5)
                let drain = followed.filter { $0[12] == 1 }
                let settled = drain.first { $0[10] <= 0.5 }
                XCTAssertNotNil(settled, "Following reaches the bottom")
                if let settled, let first = drain.first { XCTAssertLessThanOrEqual(settled[0] - first[0], 0.4) }
            }
           }
          }
        }
        try JSONSerialization.data(withJSONObject: evidence).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ai-smoothing-frames.json"))
    }
}

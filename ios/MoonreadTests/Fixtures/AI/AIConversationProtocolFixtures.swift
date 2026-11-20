import Foundation

final class AIProtocolState: @unchecked Sendable {
  let lock = NSLock()
  var mode = "complete"
  var requestCount = 0
  var stopCount = 0
  var body: Data?
  var requestEvent: (@Sendable () -> Void)?
  var stopEvent: (@Sendable () -> Void)?
  func events(request: @escaping @Sendable () -> Void, stop: @escaping @Sendable () -> Void) {
    lock.withLock {
      requestEvent = request
      stopEvent = stop
    }
  }
  func capture(_ request: URLRequest) {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = [UInt8](repeating: 0, count: 4096)
      var result = Data()
      while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        result.append(contentsOf: bytes.prefix(count))
      }
      data = result
    }
    lock.withLock { body = data }
  }
  var requestBody: Data? { lock.withLock { body } }
  func reset(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    mode = value
    requestCount = 0
    stopCount = 0
  }
  func request() -> String {
    let (value, event) = lock.withLock {
      requestCount += 1
      let event = requestEvent
      requestEvent = nil
      return (mode, event)
    }
    event?()
    TestFixtureEvents.changed()
    return value
  }
  func stopped() {
    let event = lock.withLock {
      stopCount += 1
      let event = stopEvent
      stopEvent = nil
      return event
    }
    event?()
    TestFixtureEvents.changed()
  }
  var counts: (Int, Int) {
    lock.lock()
    defer { lock.unlock() }
    return (requestCount, stopCount)
  }
}
final class AITestURLProtocol: URLProtocol, @unchecked Sendable {
  static let state = AIProtocolState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.capture(request)
    let mode = Self.state.request()
    if mode == "headers-wait" { return }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": ["xai-search", "direct-image", "google-image"].contains(mode)
            ? "application/json" : "text/event-stream"
        ])!, cacheStoragePolicy: .notAllowed)
    if mode == "body-wait" { return }
    func event(_ value: [String: Any]) {
      let data = try! JSONSerialization.data(withJSONObject: value)
      var bytes = Data("data: ".utf8)
      bytes.append(data)
      bytes.append(Data("\n\n".utf8))
      client?.urlProtocol(self, didLoad: bytes)
    }
    if mode == "google-search" {
      event([
        "candidates": [
          [
            "index": 0, "content": ["role": "model", "parts": [["text": "Google answer"]]],
            "groundingMetadata": [
              "groundingChunks": [
                [
                  "web": [
                    "uri": "https://example.com/book?signature=A%2FB", "title": "Google title",
                  ]
                ],
                [
                  "web": [
                    "uri": "https://example.com/book?signature=A%2FB", "title": "Later title",
                  ]
                ],
              ]
            ], "finishReason": "STOP",
          ]
        ],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode == "google-image" {
      let value: [String: Any] = [
        "predictions": [
          [
            "bytesBase64Encoded":
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
          ]
        ]
      ]
      client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode == "xai-search" || mode == "direct-image" {
      let png =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      let value: [String: Any] =
        mode == "direct-image"
        ? ["data": [["b64_json": png]]]
        : [
          "output": [
            [
              "type": "message",
              "content": [
                [
                  "type": "output_text", "text": "来自检索",
                  "annotations": [["url": "https://example.com/a", "title": "A"]],
                ]
              ],
            ],
            [
              "type": "web_search_call",
              "action": ["sources": [["url": "https://example.com/b", "title": "B"]]],
            ],
          ],
          "citations": ["https://example.com/c"],
          "usage": ["input_tokens": 20, "output_tokens": 10],
        ]
      client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.hasSuffix("/chat/completions") == true {
      if mode == "openrouter-replay" {
        event([
          "id": "fixture", "object": "chat.completion.chunk", "created": 1,
          "model": "fixture-model",
          "choices": [
            [
              "index": 0,
              "delta": [
                "reasoning_details": [
                  ["type": "reasoning.encrypted", "data": "opaque-replay", "id": "r1"]
                ]
              ], "finish_reason": NSNull(),
            ]
          ],
        ])
      }
      event([
        "id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
        "choices": [
          [
            "index": 0, "delta": ["role": "assistant", "content": "你好，**月读**。"],
            "finish_reason": NSNull(),
          ]
        ],
      ])
      event([
        "id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
        "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
      ])
      client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.hasSuffix("/messages") == true {
      event([
        "type": "message_start",
        "message": [
          "id": "fixture", "type": "message", "role": "assistant", "model": "fixture-model",
          "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
          "usage": ["input_tokens": 1, "output_tokens": 0],
        ],
      ])
      event([
        "type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""],
      ])
      event([
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "你好，**月读**。"],
      ])
      event(["type": "content_block_stop", "index": 0])
      event([
        "type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
        "usage": ["output_tokens": 1],
      ])
      event(["type": "message_stop"])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.contains(":streamGenerateContent") == true {
      let parts: [[String: Any]] =
        mode == "google-inline-image"
        ? [
          [
            "inlineData": [
              "mimeType": "image/png",
              "data":
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=",
            ]
          ]
        ] : [["text": "你好，**月读**。"]]
      event([
        "candidates": [
          ["content": ["role": "model", "parts": parts], "finishReason": "STOP", "index": 0]
        ],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode.hasPrefix("native-") {
      event([
        "type": "response.created",
        "response": [
          "id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "in_progress",
        ],
      ])
      if mode == "native-image" {
        let data = Data(
          base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII="
        )!
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": ["id": "image-call", "type": "image_generation_call", "status": "in_progress"],
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "image-call", "type": "image_generation_call", "status": "completed",
            "result": data.base64EncodedString(),
          ],
        ])
      } else {
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": ["id": "search-call", "type": "web_search_call", "status": "in_progress"],
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "search-call", "type": "web_search_call", "status": "completed",
            "action": ["type": "search", "query": "novel"],
          ],
        ])
        event([
          "type": "response.output_item.added", "output_index": 1,
          "item": ["id": "reply", "type": "message", "role": "assistant", "content": []],
        ])
        event([
          "type": "response.content_part.added", "item_id": "reply", "output_index": 1,
          "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []],
        ])
        event([
          "type": "response.output_text.delta", "item_id": "reply", "output_index": 1,
          "content_index": 0, "delta": "来源资料",
        ])
        event([
          "type": "response.output_text.annotation.added", "item_id": "reply", "output_index": 1,
          "content_index": 0, "annotation_index": 0,
          "annotation": [
            "type": "url_citation", "url": "https://example.com/book", "title": "Book source",
            "start_index": 0, "end_index": 4,
          ],
        ])
        event([
          "type": "response.output_item.done", "output_index": 1,
          "item": [
            "id": "reply", "type": "message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": "来源资料", "annotations": []]],
          ],
        ])
      }
      event([
        "type": "response.completed",
        "response": [
          "id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "completed",
          "usage": [
            "input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
            "output_tokens_details": ["reasoning_tokens": 0],
          ],
        ],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    event([
      "type": "response.created",
      "response": [
        "id": "fixture", "created_at": 1, "model": "fixture-model", "status": "in_progress",
      ],
    ])
    event([
      "type": "response.output_item.added", "output_index": 0,
      "item": ["id": "reply", "type": "message", "role": "assistant", "content": []],
    ])
    event([
      "type": "response.content_part.added", "item_id": "reply", "output_index": 0,
      "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []],
    ])
    event([
      "type": "response.output_text.delta", "item_id": "reply", "output_index": 0,
      "content_index": 0, "delta": "你好，**月读**。",
    ])
    if mode == "text-wait" { return }
    event([
      "type": "response.output_item.done", "output_index": 0,
      "item": [
        "id": "reply", "type": "message", "role": "assistant", "status": "completed",
        "content": [["type": "output_text", "text": "你好，**月读**。", "annotations": []]],
      ],
    ])
    event([
      "type": "response.completed",
      "response": [
        "id": "fixture", "created_at": 1, "model": "fixture-model", "status": "completed",
        "usage": [
          "input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
          "output_tokens_details": ["reasoning_tokens": 0],
        ],
      ],
    ])
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { Self.state.stopped() }
}

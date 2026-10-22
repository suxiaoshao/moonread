import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AICoverFetchTests: BookAIFixture {
  // S113: 下载内容按实际图像格式准入并记录 MIME，通用 MIME 可用、非图像拒绝；一个 PNG 正例及非图像反例。
  func testCompletedGenericMIMEImageKeepsActualFormatMetadata() async throws {
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Image", listed: false))
    await AIImageStore.shared.bind(owner, repository: repository)
    defer { Task { await AIImageStore.shared.forget(owner) } }
    // Bytes, not the source suffix or server content-type, determine acceptance.
    let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: owner)
    XCTAssertEqual(asset.attachment.mimeType, "image/png")
    var head = AIAgentHead()
    head.queue = [
      .init(
        text: "Sent image", mode: .steering,
        readingAttachments: [
          .init(
            kind: .image, origin: "fixture", title: "extensionless",
            attachmentRef: asset.attachment.id)
        ])
    ]
    try await repository.commit(
      owner, head: head, assets: [asset], references: [asset.attachment.id])
    let metadata = try await repository.asset(asset.attachment.id, sessionID: owner)
    XCTAssertEqual(metadata.mimeType, "image/png")
    do {
      _ = try await AIImageStore.shared.prepareInput(Data("completed webpage".utf8), owner: owner)
      XCTFail("Completed non-image response")
    } catch {}
  }

  // S114: 只从最终响应页提取一次候选，不递归抓取新页面；HTML 提取规则归 Rust。
  func testCoverPageExtractionUsesFinalResponseAndDoesNotRecurse() async throws {
    let source = coverSource("https://example.com/old")
    let page = "https://example.com/final/book/"
    CoverFetchURLProtocol.fixture.reset([
      source.url: .init(
        status: 200, headers: [:],
        body: Data(
          "<meta property='og:image' content='a?sig=A%2FB'><meta name='twitter:image' content='b'><img class='cover' src='/missing'>"
            .utf8), responseURL: URL(string: page)),
      page + "a?sig=A%2FB": .init(
        status: 200, headers: ["Content-Type": "text/plain"], body: coverPNG()),
      page + "b": .init(
        status: 200, headers: [:], body: Data("<meta property='og:image' content='/never'>".utf8)),
      "https://example.com/missing": .init(status: 404, headers: [:]),
    ])
    let store = CoverStageFixture()
    let result = try await coverFetcher().candidates(
      sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) },
      discard: { await store.discard($0) })
    XCTAssertEqual(result.candidates.count, 1)
    XCTAssertEqual(result.sources.first?.extractedURLs.count, 3)
    guard case .web(let origin) = result.candidates[0].origin else {
      return XCTFail("missing source")
    }
    XCTAssertEqual(origin, source)
    XCTAssertFalse(CoverFetchURLProtocol.fixture.requests.contains { $0.url?.path == "/never" })
    XCTAssertEqual(
      CoverFetchURLProtocol.fixture.requests[1].value(forHTTPHeaderField: "Referer"), page)
    let count = await store.count
    XCTAssertEqual(count, 1)
  }

  // S115: 候选去重并受上限约束，停止后无额外下载；用小注入上限，断言结果与未请求候选而非固定十次。
  func testCoverDimensionsDeduplicationAndEightCandidateStop() async throws {
    let sources = (0..<4).map { coverSource("https://example.com/\($0)") }
    let sizes = [(99, 150), (100, 150), (101, 150), (102, 150)]
    CoverFetchURLProtocol.fixture.reset(
      Dictionary(
        uniqueKeysWithValues: zip(sources, sizes).map {
          ($0.0.url, .init(status: 200, headers: [:], body: coverPNG($0.1.0, $0.1.1)))
        }))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CoverFetchURLProtocol.self]
    let store = CoverStageFixture()
    let report = try await TestAI.coverFetcher(
      configuration: config, availability: TestAI.available(), maximumCandidates: 2
    ).candidates(
      sources: [sources[0]] + sources, title: "Book", bookRef: "book",
      save: { try await store.save($0) }, discard: { await store.discard($0) })
    XCTAssertEqual(report.candidates.count, 2)
    XCTAssertFalse(
      CoverFetchURLProtocol.fixture.requests.contains { $0.url?.absoluteString == sources[3].url },
      "reaching the candidate cap stops further downloads")
    XCTAssertEqual(
      CoverFetchURLProtocol.fixture.requests.filter { $0.url?.absoluteString == sources[0].url }
        .count, 1, "duplicate source is not downloaded twice")
  }

  // S118: 失败/取消回收本次暂存资产但保留其他已提交资产；一次保存失败和一次取消 gate。
  func testCoverCancellationWithEarlierCandidatePreservesOtherAssets() async throws {
    let sources = (0..<2).map { coverSource("https://example.com/cancel/\($0)") }
    CoverFetchURLProtocol.fixture.reset([
      sources[0].url: .init(status: 200, headers: [:], body: coverPNG(100, 150)),
      sources[1].url: .init(status: 200, headers: [:], body: coverPNG(101, 150)),
    ])
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Fixture", listed: false))
    await AIImageStore.shared.bind(owner, repository: repository)
    let other = try await AIImageStore.shared.save(coverPNG(), owner: owner)
    let committed = try await AIImageStore.shared.save(coverPNG(), owner: owner)
    var head = AIAgentHead()
    head.queue = [
      .init(
        text: "Image", mode: .steering,
        readingAttachments: [
          .init(kind: .image, origin: "fixture", title: "cover", attachmentRef: committed.id)
        ])
    ]
    let assets = await AIImageStore.shared.staged(owner: owner, refs: [committed.id])
    try await repository.commit(owner, head: head, assets: assets, references: [committed.id])
    await AIImageStore.shared.didCommit(owner: owner, refs: [committed.id])
    let gate = CoverCallGate()
    let fetcher = coverFetcher()
    let tracker = CoverStageFixture()
    let task = Task {
      try await fetcher.candidates(
        sources: sources, title: "Book", bookRef: "book",
        save: { data in
          let value = try await AIImageStore.shared.save(data, owner: owner)
          await tracker.observe(value.id)
          if value.width == 101 { await gate.park() }
          return value
        }, discard: { await AIImageStore.shared.discardStaged(owner: owner, refs: $0) })
    }
    while !(await gate.started) { await Task.yield() }
    task.cancel()
    await gate.release()
    do {
      _ = try await task.value
      XCTFail("cancelled")
    } catch { XCTAssertTrue(error is CancellationError) }
    let observed = await tracker.observedIDs
    let leaked = await AIImageStore.shared.staged(owner: owner, refs: observed)
    XCTAssertEqual(observed.count, 2)
    XCTAssertTrue(leaked.isEmpty)
    let retained = await AIImageStore.shared.staged(owner: owner, refs: [other.id])
    XCTAssertEqual(retained.count, 1)
    let durable = try await repository.asset(committed.id, sessionID: owner)
    XCTAssertEqual(durable.id, committed.id)
    await AIImageStore.shared.forget(owner)
    do {
      let replies: [String: CoverFetchFixture.Reply] = Dictionary(
        uniqueKeysWithValues: sources.map { source in
          (source.url, .init(status: 200, headers: [:], body: coverPNG()))
        })
      CoverFetchURLProtocol.fixture.reset(replies)
      let failed = CoverStageFixture(failAfter: 1)
      do {
        _ = try await coverFetcher().candidates(
          sources: sources, title: "Book", bookRef: "book", save: { try await failed.save($0) },
          discard: { await failed.discard($0) })
        XCTFail("save failure must not publish a partial result")
      } catch {}
      let remaining = await failed.count
      XCTAssertEqual(remaining, 0, "earlier staged candidates must be reclaimed")
    }
  }

  // S119: 网络体积超过上限立即拒绝且不落盘；声明长度与流式实际长度各一个反例。
  func testCoverRejectsOversizedDeclaredAndStreamedBodies() async throws {
    let source = coverSource("https://example.com/image")
    let limit = AICoverImageFetcher.maximumDownloadBytes
    for declared in [true, false] {
      let reply =
        declared
        ? CoverFetchFixture.Reply(
          status: 200, headers: ["Content-Length": String(limit + 1)], body: Data())
        : CoverFetchFixture.Reply(
          status: 200, headers: [:],
          chunks: Array(repeating: Data(repeating: 65, count: 1024 * 1024), count: 11))
      CoverFetchURLProtocol.fixture.reset([source.url: reply])
      let store = CoverStageFixture()
      let report = try await coverFetcher().candidates(
        sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) },
        discard: { await store.discard($0) })
      XCTAssertTrue(report.candidates.isEmpty)
      XCTAssertEqual(report.sources.first?.failures, ["source_download:too_large"])
      let count = await store.count
      XCTAssertEqual(count, 0)
    }
  }

  // S120: 超限像素在解码分配前拒绝；与下载字节上限不同，不合并掉此防护。
  func testCoverRejectsOversizedPixelsBeforeDecode() async throws {
    // A tiny valid PNG header declares an oversized width without allocating that raster.
    var bytes = coverPNG()
    var width = UInt32(4097).bigEndian
    withUnsafeBytes(of: &width) { bytes.replaceSubrange(16..<20, with: $0) }
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes[12..<29] {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
    }
    var checksum = (crc ^ 0xffff_ffff).bigEndian
    withUnsafeBytes(of: &checksum) { bytes.replaceSubrange(29..<33, with: $0) }
    let source = coverSource("https://example.com/huge.png")
    CoverFetchURLProtocol.fixture.reset([source.url: .init(status: 200, headers: [:], body: bytes)])
    let store = CoverStageFixture()
    let report = try await coverFetcher().candidates(
      sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) },
      discard: { await store.discard($0) })
    XCTAssertTrue(report.candidates.isEmpty)
    XCTAssertEqual(report.sources.first?.failures, ["too_large"])
    let count = await store.count
    XCTAssertEqual(count, 0)
  }
}

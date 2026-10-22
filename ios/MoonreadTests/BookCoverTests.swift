import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class BookCoverReaderIntegrationTests: ReaderIntegrationFixture {
  // S358: 封面保存只接受有效内容且取消不替换旧封面；哈希校验调用 Rust，图片缩放数值/渲染矩阵删去。
  @MainActor
  func testCoverDownsamplingSaveCancelAndHashValidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let core = try ReaderCore(dataDirectory: root.path)
    let service = ReaderService(core: core)
    let book = try core.createSampleBook()
    let base = try await service.details(bookID: book.id).metadata
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3), format: format).jpegData(
      withCompressionQuality: 0.95
    ) { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }
    do {
      _ = try await service.makeCover(Data("invalid image".utf8))
      XCTFail("invalid cover accepted")
    } catch {}
    let cover = try await service.makeCover(data)
    let url = try await service.coverURL(cover)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: url.path), "Selection stays a draft until Save")
    var edited = base
    edited.cover = cover
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
}

final class BookCoverUserDataTests: UserDataFixture {
  // S480: 新封面提交后当前 presentation 可刷新，取消旧加载不能覆盖新封面；假图片载入，不搭 hosted shelf。
  @MainActor func testCoverRequestsCoalesceAndCancelledOldLoadCannotPublish() async throws {
    let old = BookCoverAsset(
      id: UUID().uuidString, sha256: String(repeating: "a", count: 64), extension: "png", width: 1,
      height: 1)
    let new = BookCoverAsset(
      id: old.id, sha256: String(repeating: "b", count: 64), extension: "png", width: 1, height: 1)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let probe = CoverLoadProbe(image: image)
    let loader = CoverImageLoader { cover, _ in
      try await probe.load(cover.id, delayed: cover.sha256 == old.sha256)
    }
    var one: CoverSubscription? = loader.subscribe(old, pixels: 320)
    var two: CoverSubscription? = loader.subscribe(old, pixels: 320)
    await probe.waitUntilStarted()
    let oldPresentation = try XCTUnwrap(one?.presentation)
    one = nil
    two = nil
    await Task.yield()
    let replacement = loader.subscribe(new, pixels: 320)
    await awaitState { replacement.presentation.phase == .ready }
    await probe.release()
    await Task.yield()
    XCTAssertNil(oldPresentation.image)
    XCTAssertTrue(replacement.presentation.image === image)
    // A completed attachment save wakes the current subscriber without a hosted view.
    do {

      let (root, service, book, store) = try await editorFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
      }
      let cover = try await service.makeCover(png)
      let directory = await service.dataDirectoryName
      let draft = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(directory)-CoverDrafts"
      ).appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
      let bytes = try Data(contentsOf: draft)
      await service.discardCoverDraft(cover)
      try await store.put(
        "metadata/\(book.contentSha256)/cover",
        value: String(
          decoding: JSONSerialization.data(withJSONObject: [
            "id": cover.id, "sha256": cover.sha256, "extension": cover.extension,
            "width": cover.width, "height": cover.height,
          ]), as: UTF8.self), device: "remote")
      let loader = CoverImageLoader { asset, pixels in
        try await service.coverImage(asset, pixels: pixels)
      }
      let subscriber = loader.subscribe(cover, pixels: 600)
      await awaitState { subscriber.presentation.phase == .waiting }
      XCTAssertNil(subscriber.presentation.image)
      // Real SwiftData save notification, no synthetic cloud notification.
      try await store.saveCover(id: cover.id, bytes: bytes)
      await awaitState { subscriber.presentation.phase == .ready }
      XCTAssertNotNil(subscriber.presentation.image)
      let same = loader.subscribe(cover, pixels: 600)
      XCTAssertTrue(same.presentation === subscriber.presentation)

    }
  }
}

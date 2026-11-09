import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class BookCoverReaderIntegrationTests: ReaderIntegrationFixture {

  func testPresetCoverAssignmentIsStable() {
    let zero = String(repeating: "0", count: 63)
    let samples: [(String, PresetBookCoverID)] = [
      (zero + "0", .bamboo), (zero + "1", .river), (zero + "2", .vermilion),
      (zero + "3", .moonlake), (zero + "4", .plum), (zero + "5", .lotus),
      ("1" + zero, .plum), ("f" + zero, .bamboo), (String(repeating: "f", count: 64), .moonlake)
    ]
    for (sha, expected) in samples { XCTAssertEqual(presetCoverID(contentSHA256: sha), expected) }
    for invalid in ["", zero, zero + "g", String(repeating: "F", count: 64), zero + "00"] {
      XCTAssertNil(presetCoverID(contentSHA256: invalid))
    }
    XCTAssertNil(presetCoverID(contentSHA256: nil))
    XCTAssertEqual(SystemPresetCoverRenderer.verticalGroups([.upright("甲"), .upright("乙"), .upright("）"), .upright("。")]), [[.upright("甲")], [.upright("乙"), .upright("）"), .upright("。")]])
    XCTAssertEqual(SystemPresetCoverRenderer.verticalTokens("  合成（1v1 NP by）  "), [.upright("合"), .upright("成"), .upright("（"), .horizontal("1v1"), .space, .horizontal("NP"), .space, .horizontal("by"), .upright("）")])
    XCTAssertEqual(SystemPresetCoverRenderer.verticalTokens("山  \t间 Journey"), [.upright("山"), .space, .upright("间"), .space, .rotated("Journey")])
  }

  // S358: 封面保存只接受有效内容且取消不替换旧封面；哈希校验调用 Rust，图片缩放数值/渲染矩阵删去。
  @MainActor
  func testCoverDownsamplingSaveCancelAndHashValidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let core = try ReaderCore(dataDirectory: root.path)
    let service = AppDataService(core: core)
    let book = try core.createSampleBook()
    let base = try await service.details(bookID: book.id).metadata
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let data = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 36), format: format).jpegData(
      withCompressionQuality: 0.95
    ) { context in
      for y in 0..<36 {
        for x in 0..<24 {
          UIColor(red: CGFloat((x * 17 + y * 11) % 256) / 255, green: CGFloat((x * 7 + y * 23) % 256) / 255, blue: CGFloat((x * 29 + y * 3) % 256) / 255, alpha: 1).setFill()
          context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
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
    let repeatedCover = try await service.importedCover(data, reusing: [cover])
    XCTAssertEqual(repeatedCover, cover, "Equivalent imported pixels must keep the existing asset ID")
    let exportedBytes = try await service.coverBytes(cover)
    let unchangedCover = try await service.importedCover(exportedBytes, reusing: [cover])
    XCTAssertEqual(unchangedCover, cover, "An exported JPEG must reuse the saved asset without recompression")
    let persistedCover = try await service.coverImage(cover, pixels: 321)
    XCTAssertNotNil(persistedCover)
    async let first = service.coverImage(cover, pixels: 321)
    async let second = service.coverImage(cover, pixels: 321)
    let images = try await (first, second)
    XCTAssertTrue(images.0 === images.1)
    XCTAssertTrue(images.0 === persistedCover)
    let exact = try await service.coverImage(cover, pixels: 80, exactSize: true)
    XCTAssertLessThanOrEqual(try XCTUnwrap(exact?.cgImage).width, 80)
    XCTAssertLessThanOrEqual(try XCTUnwrap(exact?.cgImage).height, 80)
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
    var replacement: CoverSubscription? = loader.subscribe(new, pixels: 320)
    await awaitState { replacement?.presentation.phase == .ready }
    await probe.release()
    await Task.yield()
    XCTAssertNil(oldPresentation.image)
    XCTAssertTrue(replacement?.presentation.image === image)
    replacement = nil
    await Task.yield()
    _ = await probe.calls
    await Task.yield()
    var ready: CoverSubscription? = loader.subscribe(new, pixels: 320)
    let readyPresentation = try XCTUnwrap(ready?.presentation)
    ready = nil
    let sameReady = loader.subscribe(new, pixels: 320)
    XCTAssertTrue(sameReady.presentation === readyPresentation)
    XCTAssertTrue(sameReady.presentation.image === image)
    let calls = await probe.calls
    XCTAssertEqual(calls, 2, "Only the old and new asset load; returning does not read either again")
    XCTAssertEqual(CoverImageLoader.bucket(320), 384)
    var display = BookCoverDisplay()
    let scope = UUID()
    display.accept(book: "synthetic", scope: scope, asset: old, ready: image)
    display.accept(book: "synthetic", scope: scope, asset: new, ready: nil)
    XCTAssertTrue(display.image(book: "synthetic", scope: scope, asset: new, ready: nil) === image,
      "A pending or failed replacement must not clear the successful image")
    XCTAssertNil(display.image(book: "other", scope: scope, asset: new, ready: nil))
    XCTAssertNil(display.image(book: "synthetic", scope: UUID(), asset: new, ready: nil))
    XCTAssertNil(display.image(book: "synthetic", scope: scope, asset: nil, ready: nil))
    display.accept(book: "synthetic", scope: scope, asset: nil, ready: nil)
    XCTAssertNil(display.image(book: "synthetic", scope: scope, asset: new, ready: nil))
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

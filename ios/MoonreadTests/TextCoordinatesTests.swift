import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class TextCoordinatesReaderSelectionTests: ReaderSelectionFixture {
  // S301: 复制/搜索/AI 共用选择结果，退出后旧选择任务不发布；算法 UTF-8 查询交给 Rust，仅测应用调用和取消。
  func testSelectionRangeReaderUnifiesCrossPageCopySearchAIAndCancelsOnLeave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let raw = "甲🌙段。\n \t　\n乙段。\n"
    let expected = "甲🌙段。\n乙段。\n"
    let file = root.appendingPathComponent("选取.txt")
    try Data(raw.utf8).write(to: file)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "选取")
    let service = ReaderService(core: core)
    let session = ReaderSession(service: service)
    await session.open(.book(book.id))
    await awaitState { session.window != nil }
    var clipboard = [String]()
    let copied = expectation(description: "complete projected selection delivered")
    session.readSelection(start: 0, end: book.byteCount) { range in
      XCTAssertEqual(range.startUtf8, 0)
      XCTAssertEqual(range.endUtf8, book.byteCount)
      clipboard.append(range.text)
      copied.fulfill()
    }
    XCTAssertTrue(clipboard.isEmpty)
    await fulfillment(of: [copied], timeout: 3)
    XCTAssertEqual(clipboard, [expected])
    session.readSelection(start: 0, end: book.byteCount) { clipboard.append($0.text) }
    await session.leave().value
    XCTAssertEqual(clipboard, [expected], "Leaving invalidates the pending selection owner")
  }

  // S304: 投影与原文 UTF-8/UTF-16 映射往返一致，省略区间亲和性不移动正式锚点；纯 mapping 输入。
  func testProjectionAffinitySelectionCopyAndPreviewKeepOneMapping() throws {
    let raw = "\n\n甲🌙e\u{301}👩‍👩‍👧‍👦。\n \t　\n\n乙。\n\n"
    let window = try window(raw)
    let projection = ReadingText(window)
    XCTAssertEqual(projection.text, "甲🌙e\u{301}👩‍👩‍👧‍👦。\n乙。\n")
    let seam = (projection.text as NSString).range(of: "乙").location
    let map = projection.coordinates
    let before = try XCTUnwrap(map.sourcePoint(seam, affinity: .upstream))
    let after = try XCTUnwrap(map.sourcePoint(seam, affinity: .downstream))
    XCTAssertLessThan(before, after)
    XCTAssertNil(
      map.displayRange(before..<after), "Pure blank annotations have no visible highlight")
    XCTAssertEqual(map.displayPoint(before), seam)
    let first = try XCTUnwrap(map.sourceRange(NSRange(location: 0, length: seam)))
    XCTAssertEqual(first.upperBound, before)
    let second = try XCTUnwrap(map.sourceRange(NSRange(location: seam, length: 1)))
    XCTAssertEqual(second.lowerBound, after)
    let all = try XCTUnwrap(
      map.sourceRange(NSRange(location: 0, length: projection.text.utf16.count)))
    XCTAssertTrue(all.contains(before))
    XCTAssertTrue(all.contains(after))
    XCTAssertNil(map.displayPoint(-1))
    XCTAssertNil(map.displayPoint(map.byteCount + 1))
    for segment in map.segments where segment.retained {
      for offset in 0..<segment.display.length {
        let display = segment.display.location + offset
        let original = try XCTUnwrap(map.sourcePoint(display))
        let roundtrip = try XCTUnwrap(map.displayPoint(original))
        XCTAssertEqual(map.sourcePoint(roundtrip), original)
      }
    }
    let left = projection.slice(NSRange(location: 0, length: seam))
    let right = projection.slice(
      NSRange(location: seam, length: projection.text.utf16.count - seam))
    XCTAssertEqual(left.sourceEnd, right.sourceStart)
    XCTAssertEqual(left.text + right.text, projection.text)
    let cover = projection.prefixed("\u{fffc}\n")
    XCTAssertNil(cover.coordinates.sourcePoint(0))
    XCTAssertNil(cover.coordinates.sourcePoint(1))
    XCTAssertEqual(cover.coordinates.sourcePoint(2), map.sourcePoint(0))
  }

  // S306: 全空投影不凭空生成可见正文页；只测本应用投影结果，不创建排版窗口。
  func testAllBlankProjectionHasNoSyntheticVisiblePage() {
    let raw = "\n \t　\n\n"
    let end = UInt64(raw.utf8.count)
    let window = ReadingWindow(
      chunks: [.init(index: 0, startUtf8: 0, endUtf8: end, text: raw)],
      paragraphs: [
        .init(startUtf8: 0, endUtf8: end, kind: .blank, continuation: false, indented: false)
      ], isEndOfBook: true)
    let projection = ReadingText(window)
    XCTAssertTrue(projection.text.isEmpty)
    XCTAssertNil(projection.firstVisibleOffset)
    XCTAssertNil(projection.coordinates.displayPoint(0))
    XCTAssertTrue(
      TextPage.paginate(
        window, size: .zero, attributes: [:],
        layout: { _, _ in
          return []
        }
      ).isEmpty)
  }
}

final class TextCoordinatesReaderIntegrationTests: ReaderIntegrationFixture {
  // S355: 部分重叠已有批注时应用动作使用完整批注范围，编辑不默改当前选区；仅动作描述和范围，无系统菜单。
  @MainActor
  func testSelectionMenuUsesAnyOverlapAndPreservesTheSelectedTextRange() throws {
    let mark = ReaderMark(
      id: "note", kind: .annotation, startUtf8: 3, endUtf8: 12, excerpt: "", note: "原批注", created: 1
    )
    let context = AnnotationSelection(start: 6, end: 9, annotations: [mark])
    XCTAssertEqual(context.start, 6)
    XCTAssertEqual(context.end, 9)
    XCTAssertEqual(context.marks.map(\.id), ["note"])
    let full = ReadingController.annotationRange(
      context, mapping: TextCoordinates("甲乙丙丁戊"), base: 0)
    XCTAssertEqual(
      full, NSRange(location: 2, length: 1),
      "editing preserves the original selected range")
    let menu = ReadingController().selectionMenu(for: context, suggestedActions: []) { _ in }
    let primary = try XCTUnwrap(menu.children.first as? UIMenu)
    XCTAssertEqual(
      primary.children.compactMap { ($0 as? UIAction)?.title }.prefix(2),
      [String(localized: "编辑批注"), String(localized: "移除批注")])
    XCTAssertEqual(context.start, 6, "building actions must not change the user's selection")
  }

  // S398: 封面不参与正文 offset，加入/移除封面仍按同一原文锚点恢复；纯投影输入。
  func testCoverIsOutsideTextCoordinatesAcrossWindowAndLayoutChanges() throws {
    let window = ReadingWindow(chunks: Array(readingChunks().prefix(2)))
    let body = ReadingText(window)
    let covered = body.prefixed("\u{fffc}\n")
    XCTAssertNil(covered.coordinates.sourcePoint(0))
    XCTAssertNil(covered.coordinates.sourcePoint(1))
    XCTAssertEqual(covered.coordinates.sourcePoint(2), body.coordinates.sourcePoint(0))
    let source = try XCTUnwrap(covered.coordinates.sourceRange(covered.selectableRange))
    XCTAssertEqual(UInt64(source.lowerBound) + covered.sourceStart, window.start)
    XCTAssertEqual(UInt64(source.upperBound) + covered.sourceStart, window.end)
    XCTAssertEqual(covered.slice(covered.selectableRange).text, body.text)
    let extended = ReadingText(ReadingWindow(chunks: Array(readingChunks().prefix(3)))).prefixed(
      "\u{fffc}\n")
    XCTAssertEqual(extended.coordinates.sourcePoint(2), 0)
  }

  // S421: 更新高亮不能修改正文、用户选区或阅读锚点；纯文本存储/假 viewport，不做色值截图。
  func testHighlightChangesNeverEditTextOrMoveSelectionAndViewport() {
    let layout = ReadingLayoutManager()
    var commands = [NSRange]()
    layout.invalidatePaint = { commands.append($0) }
    let mark = ReadingLayoutManager.Decoration(
      range: NSRange(location: 2, length: 3), color: .systemPink)
    layout.setDecorations([mark])
    layout.setDecorations([mark])
    XCTAssertEqual(layout.decorations, [mark])
    XCTAssertEqual(commands.count, 1)
    layout.setDecorations([])
    XCTAssertTrue(layout.decorations.isEmpty)
    XCTAssertEqual(commands.count, 2)
    XCTAssertNil(
      layout.textStorage,
      "Paint commands require neither text replacement nor a native selection/viewport")
  }

  // S422: Swift 自有 UTF-8↔UTF-16 桥接在 ASCII/多字节/代理对边界往返，和 Rust 原文 UTF-8 校准职责不同。
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

  // S423: 合成 page spans 跨窗口拼接无丢字/重复，重叠窗口保留正确边界；一个前移和一个回移，不测 TextKit。
  @MainActor func testPaginationCoversChunkWithoutMissingOrRepeatedBytes() {
    let text = String(repeating: "月🌙👨‍👩‍👧‍👦e\u{301}。\n", count: 5)
    let window = ReadingWindow(chunks: [
      .init(index: 0, startUtf8: 321, endUtf8: 321 + UInt64(text.utf8.count), text: text)
    ])
    let pages = syntheticPages(window)
    XCTAssertGreaterThan(pages.count, 1)
    assertCoverage(pages, window: window)
    for page in pages {
      XCTAssertEqual(page.readingText.sourceStart, page.start)
      XCTAssertEqual(page.readingText.sourceEnd, page.end)
    }
    let chunks = readingChunks()
    let first = ReadingWindow(chunks: Array(chunks.prefix(3)))
    let next = ReadingWindow(chunks: Array(chunks[1...3]))
    let firstPages = syntheticPages(first)
    let forward = syntheticPages(next, preserving: firstPages)
    assertCoverage(forward, window: next)
    assertCoverage(syntheticPages(first, preserving: forward), window: first)
  }
}

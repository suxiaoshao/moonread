import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class FileAccessBoundaryReaderIntegrationTests: ReaderIntegrationFixture {
  // S381: 平台读文件允许父路径别名但拒绝叶子 symlink，防越授权边界；必须保留 Swift 安全校验。
  func testByteValidationAllowsParentAliasesAndRejectsLeafSymlinks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    let alias = root.appendingPathComponent("alias")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    let file = real.appendingPathComponent("book.txt")
    try Data("same file".utf8).write(to: file)
    try fm.createSymbolicLink(at: alias, withDestinationURL: real)
    let expected = try CloudDocumentHandoff.bytesHash(file)
    XCTAssertNoThrow(
      try CloudDocumentHandoff.verifyBytes(
        alias.appendingPathComponent("book.txt"), expectedHash: expected))
    let leaf = real.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: leaf, withDestinationURL: file)
    XCTAssertThrowsError(try CloudDocumentHandoff.verifyBytes(leaf, expectedHash: expected))
  }

  // S406: 授权根的 alias 解析后才计算相对路径，不误将合法子文件判为外部文件。
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
    let service = AppDataService(
      core: core, libraryDirectory: alias.appendingPathComponent("Documents"))
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

  // S419: 平台源验证不能只信 mtime/长度，同大小同时间的字节变化必须使快开失效；算法 SHA 归 Rust。
  func testRawSHADetectsSameLengthEditWithPreservedModificationDate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("revision.txt")
    try Data("第一章 起点\n正文甲".utf8).write(to: url)
    let modified = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    let service = AppDataService()
    let initialValue = try CloudDocumentHandoff.bytesHash(url)
    let initial = try XCTUnwrap(initialValue)
    let unchanged = try CloudDocumentHandoff.bytesHash(url)
    XCTAssertEqual(initial, unchanged, "Unchanged local files must be reusable")

    try Data("第一章 起点\n正文乙".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    let changedValue = try CloudDocumentHandoff.bytesHash(url)
    let changed = try XCTUnwrap(changedValue)
    XCTAssertNotEqual(
      initial, changed,
      "Preserving size and modification time must not reuse stale text")
  }
}

final class FileAccessBoundaryLibraryTrashTests: LibraryTrashFixture {
  // S433: 已移入垃圾箱的授权根视为不可用但不重写 bookmark，名称类似的正常根不能误拒绝。
  func testTrashRootIsMissingWithoutScanOrBookmarkRewriteButTrashyRootIsUsable() async throws {
    let probe = TrashIOProbe()
    let (temporary, core, service, _) = try await fixture(
      deletion: { _, _ in },
      scan: { root, _ in
        probe.record(root.path)
        return try AppDataService.libraryDirectoryItems(root)
      })
    defer { try? FileManager.default.removeItem(at: temporary) }
    let deleted = temporary.appendingPathComponent(".Trash/root")
    let sibling = temporary.appendingPathComponent(".Trashy/root")
    for root in [deleted, sibling] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let id = try await service.registerLibraryShelf(deleted)
    let bookmark = try XCTUnwrap(core.libraryShelves().first { $0.id == id }).bookmark
    let before = probe.values().count
    do {
      try await service.scanLibraryShelf(id)
      XCTFail("A trashed root is unavailable")
    } catch LibraryFileError.missingShelf {}
    XCTAssertEqual(probe.values().count, before)
    let shelf = try XCTUnwrap(core.libraryShelves().first { $0.id == id })
    XCTAssertNotNil(shelf.error)
    XCTAssertEqual(shelf.bookmark, bookmark)
    XCTAssertTrue(
      shelf.error?.contains("重新连接") == true || shelf.error?.contains("reconnect") == true)
    let other = try await service.registerLibraryShelf(sibling)
    try await service.scanLibraryShelf(other)
    XCTAssertNil(try core.libraryShelves().first { $0.id == other }?.error)
  }
}

final class ProtectedFileAccessTests: XCTestCase {
  func testContainedAliasesRejectSiblingEscapeAndRestorationLeafSymlink() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let root = directory.appendingPathComponent("shelf")
    let sibling = directory.appendingPathComponent("shelf-other")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("book.txt")
    try Data("Synthetic source".utf8).write(to: file)
    let alias = directory.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    let source = try ProtectedFileAccess.Source(bookmark: alias.bookmarkData(), relativePath: "book.txt")
    defer { withExtendedLifetime(source) {} }
    let direct = try ProtectedFileAccess.Source(bookmark: root.bookmarkData(), relativePath: "book.txt")
    defer { withExtendedLifetime(direct) {} }
    XCTAssertTrue(try direct.availableDirectory())
    XCTAssertNoThrow(try source.requireContained())
    XCTAssertNoThrow(try source.validateRestoration())
    XCTAssertThrowsError(try source.requireContained(sibling.appendingPathComponent("book.txt")))
    let escaped = try ProtectedFileAccess.Source(bookmark: root.bookmarkData(), relativePath: "../shelf-other/book.txt")
    defer { withExtendedLifetime(escaped) {} }
    XCTAssertThrowsError(try escaped.requireContained())
    let link = root.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertNoThrow(try source.requireContained(link), "An in-root alias is contained; restoration separately rejects leaf links")
    XCTAssertThrowsError(try source.validateRestoration(link))
    let trash = directory.appendingPathComponent(".Trash/shelf")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let discarded = try ProtectedFileAccess.Source(bookmark: trash.bookmarkData(), relativePath: "book.txt")
    defer { withExtendedLifetime(discarded) {} }
    XCTAssertFalse(try discarded.availableDirectory())
    XCTAssertThrowsError(try discarded.validateRestoration())
  }

  func testReadPreservesAccessorErrorsAndSuccessfulNil() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("Original synthetic bytes".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let access = ProtectedFileAccess()
    enum Failure: Error { case accessor }
    XCTAssertThrowsError(try access.read(at: file) { _ in throw Failure.accessor }) { error in
      XCTAssertTrue(error is Failure)
    }
    let value: String? = try access.read(at: file) { _ in nil }
    XCTAssertNil(value, "A delivered nil is not a missing accessor")
    XCTAssertThrowsError(try ProtectedFileAccess.Source(bookmark: Data(), relativePath: "book.txt"))
  }

  func testCancellationDoesNotRunAsyncAccessor() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("Synthetic bytes".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let access = ProtectedFileAccess()
    access.cancel()
    do {
      _ = try await access.readAsync(at: file) { _ in XCTFail("Cancelled access must not start source I/O"); return true }
      XCTFail("Expected cancellation")
    } catch is CancellationError { }
  }
}

import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderSessionApplicationStateTests: ApplicationStateFixture {
  func testSystemRequestConfirmsDirtyStateAndCancellationConsumesIt() {
    let library = LibraryModel()
    let router = library.systemReading
    let opening = OpeningRequest(target: .book("source-boundary-fixture"))
    library.libraryPath = [.folder(.init(shelfID: "builtin")), .reader(opening)]
    XCTAssertEqual(library.readerDestinationDepth(opening.id), 3, "the folder's appearance cannot settle the following reader push")
    XCTAssertTrue(library.containsReaderDestination(opening.id))
    library.removeReaderDestination(opening.id)
    XCTAssertNil(library.readerDestinationDepth(opening.id))
    router.hasUnsavedEdits = { true }
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "test", library: library))
    XCTAssertEqual(router.confirmationTitle, "test")
    router.answerConfirmation(discard: false)
    XCTAssertNil(router.pending)
    router.resume()
    XCTAssertNil(router.pending, "A cancelled request must not replay on later presentation events")
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "first", library: library))
    let oldRequest = router.requestID
    router.submit(.showStatistics)
    XCTAssertFalse(router.admit(title: "second", library: library))
    router.answerConfirmation(discard: false, expectedID: oldRequest)
    XCTAssertEqual(router.pending, .showStatistics, "An old alert callback cannot consume the replacement")
    router.answerConfirmation(discard: false, expectedID: router.requestID)
    XCTAssertNil(router.pending)
    router.savingEdits = { true }
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "saving", library: library))
    XCTAssertNil(router.pending, "An in-flight save is not cancelled or queued behind")
    XCTAssertNotNil(router.requestError)
    XCTAssertTrue(router.presentsConfirmation(active: true, editor: false))
    XCTAssertFalse(router.presentsConfirmation(active: false, editor: false))
    XCTAssertFalse(router.presentsConfirmation(active: true, editor: true))
    router.savingEdits = { false }
    router.requestError = nil
    router.hasUnsavedEdits = { false }
    XCTAssertTrue(router.admit(title: "test", library: library), "An open but clean editor does not block a request")
  }

  func testReaderEditorKeepsItsOwnerAndInputUntilThatSessionFinishes() throws {
    let tools = ReaderToolSession()
    tools.send(.open(.settings(.main)))
    tools.setSettingsPreview(true)
    let parent = try XCTUnwrap(tools.render.visit?.id)
    let palette = PaletteDraft(palette: try XCTUnwrap(defaultThemeSnapshot().palettes.first), creating: true)
    tools.settingsEditing.beginPalette(palette, presenter: .preview)
    let first = try XCTUnwrap(tools.editor)
    palette.palette.name = "未保存的输入"; palette.error = "保存失败"
    tools.send(.open(.library(.listing(.chapters))))
    XCTAssertEqual(tools.render.sourcePage, .settings)
    XCTAssertTrue(tools.editor === first)
    XCTAssertTrue(tools.settingsEditing.draft === palette)
    XCTAssertEqual(palette.palette.name, "未保存的输入")
    tools.finishEditing(UUID())
    XCTAssertTrue(tools.editor === first)
    tools.finishEditing(first.id)
    XCTAssertNil(tools.settingsEditing.draft)
    XCTAssertEqual(tools.render.visit?.id, parent)
    XCTAssertTrue(tools.settingsPreviewPresented)
    tools.setSettingsPreview(false)
    tools.send(.closeVisit(parent))
    XCTAssertNil(tools.render.sourcePage)
    tools.send(.open(.library(.listing(.chapters))))
    let listing = tools.render.visit?.id
    let chapter = ChapterEditDraft(start: 4, title: "原名", level: 1)
    tools.libraryEditing.beginChapter(chapter)
    let next = try XCTUnwrap(tools.editor)
    chapter.title = "实际输入"; chapter.level = 0
    tools.finishEditing(first.id)
    XCTAssertTrue(tools.editor === next, "a late callback cannot finish a replacement draft")
    XCTAssertEqual(tools.libraryEditing.chapterEdit?.title, "实际输入")
    tools.finishEditing(next.id)
    XCTAssertNil(tools.libraryEditing.chapterEdit)
    XCTAssertEqual(tools.render.visit?.id, listing)
  }

  // S440: 取消搜索返回实际入口 tab，不把统计入口错误送回书架。
  func testSearchCancelReturnsToActualOriginAndSettingsTabRemainsValid() {
    let model = LibraryModel()
    model.selectedTab = .statistics
    model.selectedTab = .search
    model.setSearchPresented(true)
    model.setSearchPresented(false)
    XCTAssertEqual(model.selectedTab, .statistics)
    model.selectedTab = .conversations
    model.updateAvailableTabs(aiAvailable: false)
    XCTAssertEqual(model.selectedTab, .library)
    model.selectedTab = .settings
    model.updateAvailableTabs(aiAvailable: true)
    XCTAssertEqual(model.selectedTab, .settings)
    let loading = LoadingState()
    let old = loading.begin()
    let new = loading.begin()
    loading.finish(old)
    XCTAssertEqual(loading.request, new)
    loading.finish(new)
    XCTAssertFalse(loading.active)
  }
  func testPresentationIntentDoesNotFollowBodyLayoutAndRejectsOldHostInput() async throws {
    let tools = ReaderToolSession()
    let opening = tools.opening
    tools.send(.openSearch)
    let search = tools.render.context
    XCTAssertTrue(tools.render.expanded)
    tools.send(.collapse, from: search)
    XCTAssertTrue(tools.tools.searchActive)
    XCTAssertEqual(tools.render.compact, .search)
    XCTAssertFalse(tools.render.expanded)
    tools.send(.endSearch, from: search)
    XCTAssertTrue(tools.tools.searchActive, "a stale action cannot close the replacement render")
    tools.send(.endSearch, from: tools.render.context)
    XCTAssertFalse(tools.tools.searchActive)

    tools.send(.showChrome)
    let host = tools.host
    host.update(tools.render)
    let old = try XCTUnwrap(host.token)
    XCTAssertFalse(tools.acceptsNativeInput(old, generation: tools.revision))
    tools.send(.nativeConfirmed(old))
    XCTAssertTrue(tools.acceptsNativeInput(old, generation: tools.revision))
    tools.send(.quick(.more))
    host.update(tools.render)
    let current = try XCTUnwrap(host.token)
    XCTAssertEqual(old.id, current.id)
    XCTAssertFalse(tools.acceptsNativeInput(old, generation: tools.revision))
    XCTAssertTrue(tools.acceptsNativeInput(current, generation: tools.revision))

    tools.send(.open(.settings(.main)))
    let visit = try XCTUnwrap(tools.render.visit?.id)
    host.update(nil)
    XCTAssertTrue(host.dismissing)
    XCTAssertEqual(host.node?.compact, .more)
    tools.send(.nativeDismissed(old))
    XCTAssertEqual(tools.render.sourcePage, .settings, "releasing the dock cannot close the pushed visit")
    tools.send(.closeVisit(visit))
    XCTAssertNil(tools.render.sourcePage)
    tools.send(.quick(.more))
    tools.send(.open(.library(.listing(.notes))))
    let library = try XCTUnwrap(tools.render.visit?.id)
    tools.send(.closeVisit(library))
    XCTAssertEqual(tools.render.compact, .more)
    tools.send(.closeVisit(library))
    XCTAssertEqual(tools.render.compact, .more, "a stale source return cannot close a replacement visit")
    let canvas = CGRect(x: 0, y: 0, width: 1200, height: 900)
    XCTAssertFalse(ReadingContainerRegions.valid(CGRect(x: 0, y: 71, width: 1200, height: 5), inside: canvas, minimumHeight: 44))
    XCTAssertFalse(ReadingContainerRegions.valid(CGRect(x: 0, y: -50, width: 1200, height: 900), inside: canvas, minimumHeight: 44))
    let region = try XCTUnwrap(ReadingContainerRegions.available(canvas, blocked: [CGRect(x: 900, y: 0, width: 300, height: 900)]).first)
    XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 900, height: 900), "a vertical reservation must not become a bottom inset")
    XCTAssertTrue(ReadingContainerRegions.valid(region, inside: canvas, minimumHeight: 44))
    let unmounted = ReaderPresentationHost()
    unmounted.update(tools.render)
    let unused = try XCTUnwrap(unmounted.token)
    unmounted.update(nil)
    XCTAssertNil(unmounted.token, "an unconfirmed request cancels without waiting for disappear")
    tools.beginOpening(UUID())
    tools.send(.showChrome)
    unmounted.update(tools.render)
    let nextRequest = try XCTUnwrap(unmounted.token)
    unmounted.confirmed(unused)
    XCTAssertFalse(unmounted.completed(unused))
    XCTAssertEqual(unmounted.phase, .requested, "a late mount cannot confirm the replacement opening")
    XCTAssertEqual(unmounted.token, nextRequest)
    XCTAssertFalse(ReadingContainerRegions.permitsSpread(in: CGSize(width: 900, height: 900)))
    XCTAssertTrue(ReadingContainerRegions.permitsSpread(in: CGSize(width: 1000, height: 900)))
  }

}

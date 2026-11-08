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
    let state = tools.presentation
    state.choose(.settings, exposure: .expanded)
    state.push(.fullSettings)
    tools.settingsEditing.previewPresented = true
    let parent = state.location
    let palette = PaletteDraft(palette: try XCTUnwrap(defaultThemeSnapshot().palettes.first), creating: true)
    tools.settingsEditing.beginPalette(palette, presenter: .preview)
    let first = try XCTUnwrap(tools.editor)
    palette.palette.name = "未保存的输入"; palette.error = "保存失败"
    state.choose(.library, exposure: .accessory)
    XCTAssertEqual(state.location.selection, .settings, "switching tools cannot silently discard an editor")
    XCTAssertTrue(tools.editor === first)
    XCTAssertTrue(tools.settingsEditing.draft === palette)
    XCTAssertEqual(palette.palette.name, "未保存的输入")
    XCTAssertEqual(palette.error, "保存失败")
    tools.finishEditing(UUID())
    XCTAssertTrue(tools.editor === first)
    tools.finishEditing(first.id)
    XCTAssertNil(tools.settingsEditing.draft)
    XCTAssertEqual(state.location, parent, "finishing pops only the editor; its preview/settings remain")
    XCTAssertTrue(tools.editor(first.id) === first, "outgoing native content retains its object until released")
    tools.releaseEditor(first.id)
    XCTAssertNil(tools.editor(first.id))
    tools.settingsEditing.previewPresented = false
    XCTAssertEqual(state.location.path, [.fullSettings])
    state.location.path = []; state.choose(.search, exposure: .expanded)
    tools.beginEditing(.chapter(ChapterEditDraft(start: 1, title: "第一次", level: 1)), presenter: .readerTask)
    let inline = try XCTUnwrap(tools.editor)
    tools.finishEditing(inline.id)
    XCTAssertEqual(state.location.selection, .search)
    let chapter = ChapterEditDraft(start: 4, title: "原名", level: 1)
    tools.libraryEditing.beginChapter(chapter)
    let next = try XCTUnwrap(tools.editor)
    chapter.title = "实际输入"; chapter.level = 0
    tools.finishEditing(first.id)
    XCTAssertTrue(tools.editor === next, "a late callback cannot finish a replacement draft")
    XCTAssertEqual(tools.libraryEditing.chapterEdit?.title, "实际输入")
    XCTAssertEqual(tools.libraryEditing.chapterEdit?.level, 0)
    tools.finishEditing(next.id)
    tools.releaseFinishedEditors()
    XCTAssertNil(tools.libraryEditing.chapterEdit)
    XCTAssertEqual(state.location.selection, .search)
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
    let state = ReaderPresentationState()
    state.choose(.settings, exposure: .expanded)
    let draft = UUID(); state.push(.palette(draft))
    let location = state.location
    XCTAssertEqual(state.location, location)
    state.choose(.settings, exposure: .expanded)
    XCTAssertEqual(state.location, location, "reselecting the same tool preserves its child")
    let native = ReaderNativeInstallation(); let opening = UUID()
    let old = native.install(opening: opening, generation: state.revision)
    state.push(.history)
    let current = native.install(opening: opening, generation: state.revision)
    XCTAssertEqual(old.id, current.id, "content changes do not replace a native presenter")
    XCTAssertFalse(native.acceptsInput(old, opening: opening, generation: state.revision))
    XCTAssertEqual(native.phase, .requested)
    XCTAssertFalse(native.acceptsInput(current, opening: opening, generation: state.revision))
    native.confirm(current)
    XCTAssertEqual(native.phase, .confirmed)
    XCTAssertTrue(native.acceptsInput(current, opening: opening, generation: state.revision))
    native.beginDismissal()
    XCTAssertFalse(native.acceptsInput(current, opening: opening, generation: state.revision))
    XCTAssertTrue(native.completed(old), "completion releases the same physical installation only")
    let replacement = native.install(opening: opening, generation: state.revision)
    XCTAssertFalse(native.completed(old))
    XCTAssertEqual(native.token, replacement)
    let host = ReaderPresentationHost()
    state.location.path = [.fullSettings]; state.exposure = .expanded
    XCTAssertEqual(ReaderPresentationProjection.target(state: state, editorParent: nil,
      hasNote: false, hasAccessory: false, available: true), .settings)
    host.update(.dock, opening: opening, generation: state.revision)
    let dock = try XCTUnwrap(host.token)
    host.confirmed(dock)
    host.retain(ReaderInstalledNode(location: state.location, exposure: state.exposure, controls: false,
      searchActive: false, noteID: nil, noteEditor: nil, editor: nil))
    host.update(.settings, opening: opening, generation: state.revision)
    XCTAssertTrue(host.dismissing)
    XCTAssertEqual(host.showing, .none, "release the sheet before the source stack pushes")
    XCTAssertEqual(host.node?.panel, .settings, "retain the outgoing node until actual completion")
    XCTAssertTrue(host.completed(dock))
    host.update(.settings, opening: opening, generation: state.revision)
    XCTAssertEqual(host.showing, .settings)
    XCTAssertFalse(host.completed(dock))
    state.reset()
    XCTAssertEqual(ReaderPresentationProjection.target(state: state, editorParent: nil,
      hasNote: false, hasAccessory: false, available: true), .none)
    let tools = ReaderToolSession()
    let nativeToken = tools.host.installation.install(opening: opening, generation: tools.presentation.revision)
    tools.host.confirmed(nativeToken)
    XCTAssertTrue(tools.acceptsNativeInput(nativeToken, generation: tools.presentation.revision))
    let intent = ReaderPresentationState()
    intent.controlsVisible = true; intent.choose(.search, exposure: .expanded)
    XCTAssertFalse(intent.controlsVisible)
    intent.expandSearch(false); intent.setControlsVisible(false); intent.expandSearch(true)
    XCTAssertEqual(intent.location.selection, .search)
    XCTAssertEqual(intent.exposure, .expanded, "collapsed search reopens through the same binding")
    intent.choose(.settings, exposure: .accessory); intent.setControlsVisible(false)
    XCTAssertEqual(intent.location.selection, .library, "hiding phone quick tools restores progress")
    intent.choose(.settings, exposure: .expanded); intent.setControlsVisible(false)
    XCTAssertEqual(intent.location.selection, .settings, "hiding reader chrome does not replace the active task")
    intent.reset(); intent.choose(.automatic, exposure: .accessory)
    let autoHost = ReaderPresentationHost()
    autoHost.update(.dock, opening: opening, generation: intent.revision)
    let autoToken = try XCTUnwrap(autoHost.token); autoHost.confirmed(autoToken)
    for target: ReaderTool in [.more, .settings] {
      intent.controlsVisible = false; intent.choose(.automatic, exposure: .accessory)
      XCTAssertTrue(intent.leaveAutomaticAccessory(for: target))
      XCTAssertTrue(intent.controlsVisible, "A footer selection restores the ordinary four tools")
      XCTAssertEqual(intent.location.selection, target)
      let projection = ReaderPresentationProjection.target(state: intent, editorParent: nil,
        hasNote: false, hasAccessory: false, available: true)
      XCTAssertEqual(projection, .dock)
      autoHost.update(projection, opening: opening, generation: intent.revision)
      XCTAssertEqual(autoHost.token?.id, autoToken.id, "Switch content without dismissing the sheet")
      XCTAssertFalse(autoHost.dismissing)
    }
    let search = ReaderToolsModel()
    search.beginSearchSession()
    await search.prepare(bookID: "search-fixture", currentChapter: 0, library: false)
    XCTAssertTrue(search.searchActive, "preparing the first window is not closing the search session")
    search.query = ""; search.startSearch()
    XCTAssertTrue(search.searchActive, "an empty query is still an active search")
    search.stopSearch(); XCTAssertFalse(search.searchActive)
    let canvas = CGRect(x: 0, y: 0, width: 1200, height: 900)
    XCTAssertFalse(ReadingContainerRegions.valid(CGRect(x: 0, y: 71, width: 1200, height: 5), inside: canvas, minimumHeight: 44))
    XCTAssertFalse(ReadingContainerRegions.valid(CGRect(x: 0, y: -50, width: 1200, height: 900), inside: canvas, minimumHeight: 44))
    let region = try XCTUnwrap(ReadingContainerRegions.available(canvas, blocked: [CGRect(x: 900, y: 0, width: 300, height: 900)]).first)
    XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 900, height: 900), "a vertical reservation must not become a bottom inset")
    XCTAssertTrue(ReadingContainerRegions.valid(region, inside: canvas, minimumHeight: 44))
    let unmounted = ReaderNativeInstallation()
    let unused = unmounted.install(opening: opening, generation: 0)
    unmounted.beginDismissal()
    XCTAssertNil(unmounted.token, "an unconfirmed request cancels without waiting for disappear")
    let nextRequest = unmounted.install(opening: UUID(), generation: 1)
    unmounted.confirm(unused)
    XCTAssertEqual(unmounted.phase, .requested, "a late mount cannot confirm the replacement opening")
    XCTAssertEqual(unmounted.token, nextRequest)
    let shared = ReaderPresentationState()
    shared.controlsVisible = true
    XCTAssertEqual(ReaderPresentationProjection.target(state: shared, editorParent: nil,
      hasNote: false, hasAccessory: false, available: true), .dock)
    shared.push(.library)
    XCTAssertEqual(ReaderPresentationProjection.target(state: shared, editorParent: .library,
      hasNote: false, hasAccessory: false, available: true), .dock)
    shared.push(.chapter(UUID()))
    XCTAssertEqual(ReaderPresentationProjection.target(state: shared, editorParent: .library,
      hasNote: false, hasAccessory: false, available: true), .dock)
    shared.reset()
    shared.sourcePage = .fullSettings
    shared.push(.preview(UUID()))
    shared.controlsVisible.toggle() // unrelated tool revisions never veto Back
    shared.sourcePage = nil
    XCTAssertNil(shared.sourcePage)
    XCTAssertTrue(shared.location.path.isEmpty)
    shared.sourcePage = .details
    shared.push(.history)
    XCTAssertEqual(shared.sourcePage, .details, "a deeper child does not end its reader-owned page")
    shared.sourcePage = nil // also the programmatic return-to-reading path
    XCTAssertTrue(shared.location.path.isEmpty)
    XCTAssertFalse(ReadingContainerRegions.permitsSpread(in: CGSize(width: 900, height: 900)))
    XCTAssertTrue(ReadingContainerRegions.permitsSpread(in: CGSize(width: 1000, height: 900)))
  }

}

import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReadingActivityReadingReviewTests: ReadingReviewFixture {
  // S274: 只测 recorder 把暂停/预览/停止事件正确传给 Rust 并只提交返回 slices；idle 时长算法仅 R048/R049，删 Swift 重算。
  @MainActor func testEffectiveSessionDurationUsesReadingClockIdleAndPauseRules() async throws {
    func readable(_ body: Bool = true, _ preparation: Bool = false, _ share: Bool = false,
                  _ alert: Bool = false, _ chooser: Bool = false) -> Bool {
      ReaderStatisticsVisibility.isReadable(body: body, preparingExcerpt: preparation,
        excerptPresented: share, confirmationPresented: alert, choosingAnnotations: chooser)
    }
    XCTAssertTrue(readable())
    XCTAssertFalse(readable(true, true)) // Before the selection read starts.
    XCTAssertFalse(readable(true, false, true)) // Sheet after preparation ends.
    XCTAssertFalse(readable(true, false, false, true))
    XCTAssertFalse(readable(true, false, false, false, true))
    XCTAssertFalse(readable(false), "Dismissing a task cannot override another unreadable condition")
    let controller = ReadingController(), chooser = UIAlertController()
    var chooserVisible = true
    controller.annotationChooser = chooser
    controller.annotationChooserChanged = { chooserVisible = $0 }
    let dismissed = AnnotationChooserDelegate { controller.finishAnnotationChooser(chooser) }
    dismissed.presentationControllerDidDismiss(UIPresentationController(presentedViewController: chooser, presenting: controller))
    XCTAssertFalse(chooserVisible)
    XCTAssertNil(controller.annotationChooser)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AppDataService(core: try ReaderCore(dataDirectory: root.path))
    let clock = ReviewTestTime()
    let viewport = ReadingViewportAccess(
      capture: {
        ReadingViewport(
          offset: 0, lineY: 0, size: .zero, settings: defaultReaderSettings(), typeSize: .large,
          pages: [])
      }, range: { (0, 30) })
    var slices: [ReadingSlice] = []
    var generations: [UInt64] = []
    let writer = StatisticsWriter { values, generation in
      slices += values
      generations.append(generation)
    }
    let recorder = ReadingActivityRecorder(
      writer: writer,
      time: {
        ReadingActivityTime(uptime: clock.elapsed, date: self.now.addingTimeInterval(clock.elapsed))
      }
    ) { StatisticsPreferences(enabled: true, generation: 17) }
    let attempt = UUID()
    recorder.prepareStart(attempt)
    await recorder.start(
      lease: ReadingLease(id: "activity-fixture", service: service), viewport: viewport,
      attempt: attempt)
    recorder.update(readable: true, preview: false)
    recorder.interacted()
    clock.elapsed = 1
    recorder.update(readable: true, preview: true)
    clock.elapsed = 2
    recorder.update(readable: false, preview: true)
    await recorder.flush()
    XCTAssertTrue(slices.contains { !$0.preview }, "formal reading is passed to the writer")
    XCTAssertTrue(slices.contains { $0.preview }, "preview facts remain distinguishable")
    XCTAssertTrue(slices.allSatisfy { $0.bookId == "activity-fixture" })
    XCTAssertTrue(generations.allSatisfy { $0 == 17 })
    let ids = slices.map(\.id)
    recorder.stop()
    await writer.drain()
    XCTAssertEqual(slices.map(\.id), ids, "stop must not resend already flushed facts")
  }
}

final class ReadingActivityReaderIntegrationTests: ReaderIntegrationFixture {
  // S311: 取消/离开/失败前后的晚到 activity lease 必须释放且不回填可见前时长；两个受控时序。
  @MainActor func testActivityStartCancellationAndStopReleaseLateLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AppDataService(core: try ReaderCore(dataDirectory: root.path))
    let entered = expectation(description: "preferences suspended")
    let gate = SourceReadinessGate(entered: entered)
    let recorder = ReadingActivityRecorder {
      await gate.wait()
      return StatisticsPreferences(enabled: true, generation: 0)
    }
    let token = UUID()
    recorder.prepareStart(token)
    var lease: ReadingLease? = ReadingLease(id: "cancelled", service: service)
    weak var retained = lease
    let task = Task { [lease = lease!] in
      await recorder.start(lease: lease, viewport: ReadingViewportAccess(), attempt: token)
    }
    lease = nil
    await fulfillment(of: [entered], timeout: 2)
    task.cancel()
    recorder.stop()
    await gate.release()
    await task.value
    XCTAssertNil(recorder.recordingBookID)
    XCTAssertFalse(recorder.hasSamplingTimer)
    for _ in 0..<20 {
      if retained == nil { break }
      await Task.yield()
    }
    XCTAssertNil(retained)
  }

  // S312: 旧开始请求晚到不得替换新会话计时 owner，两个确定 gate。
  @MainActor func testActivityOldAttemptCannotOverwriteNewClock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AppDataService(core: try ReaderCore(dataDirectory: root.path))
    let entered = expectation(description: "old preferences")
    let gate = SourceReadinessGate(entered: entered)
    var calls = 0
    let recorder = ReadingActivityRecorder {
      calls += 1
      if calls == 1 { await gate.wait() }
      return StatisticsPreferences(enabled: true, generation: 0)
    }
    let old = UUID()
    recorder.prepareStart(old)
    let task = Task {
      await recorder.start(
        lease: ReadingLease(id: "old", service: service), viewport: ReadingViewportAccess(),
        attempt: old)
    }
    await fulfillment(of: [entered], timeout: 2)
    let fresh = UUID()
    recorder.prepareStart(fresh)
    await recorder.start(
      lease: ReadingLease(id: "new", service: service), viewport: ReadingViewportAccess(),
      attempt: fresh)
    XCTAssertEqual(recorder.recordingBookID, "new")
    recorder.update(readable: false, preview: false)  // Background state remains authoritative during a late start.
    await gate.release()
    await task.value
    XCTAssertEqual(recorder.recordingBookID, "new")
    XCTAssertTrue(recorder.hasSamplingTimer)
    recorder.stop()
  }

  // S314: recorder 停止后仍等已承诺统计写入完成才释放 lease，不丢最后一段记录。
  @MainActor func testStatisticsWriterKeepsLeaseUntilPendingWriteFinishesAfterRecorderStops()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AppDataService(core: try ReaderCore(dataDirectory: root.path))
    let entered = expectation(description: "pending writer")
    let gate = SourceReadinessGate(entered: entered)
    let writer = StatisticsWriter { _, _ in await gate.wait() }
    var lease: ReadingLease? = ReadingLease(id: "pending-write", service: service)
    weak var retained = lease
    let clock = ReadingClock(bookId: "pending-write")
    var moment = ReadingMoment(
      monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true,
      preview: false, startUtf8: 0, endUtf8: 9)
    _ = clock.update(moment: moment)
    moment.monotonicMs = 1000
    moment.unixMs = 1000
    moment.readable = false
    let slices = clock.update(moment: moment)
    XCTAssertFalse(slices.isEmpty)
    writer.enqueue(slices, generation: 0, lease: lease!)
    let recorder = ReadingActivityRecorder()
    recorder.stop()
    lease = nil
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertNotNil(retained, "Cancelling startup must not invalidate a writer-owned lease")
    await gate.release()
    await writer.drain()
    for _ in 0..<20 {
      if retained == nil { break }
      await Task.yield()
    }
    XCTAssertNil(retained)
  }
}

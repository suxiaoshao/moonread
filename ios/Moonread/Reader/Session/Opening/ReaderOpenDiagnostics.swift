import Foundation
import os
import Darwin

/// Release diagnostics compile out of the delivered application. No text or SHA is logged.
enum ReaderOpenDiagnostics {
    static var enabled: Bool {
        #if READER_OPEN_DIAGNOSTICS
        true
        #else
        false
        #endif
    }
    static var benchmark: Bool {
        #if READER_OPEN_DIAGNOSTICS
        ProcessInfo.processInfo.arguments.contains("--reader-open-benchmark")
        #else
        false
        #endif
    }
    #if READER_OPEN_DIAGNOSTICS
    /// A diagnostic session is deliberately separate from every UI-test argument.
    static var session: String? {
        argument("--reader-open-session").flatMap { UUID(uuidString: $0)?.uuidString }
    }
    #endif
    #if READER_OPEN_DIAGNOSTICS
    private final class Variant: @unchecked Sendable {
        let lock = NSLock()
        var selected: String?
    }
    private static let selection = Variant()
    #endif
    static func selectVariant(_ value: String) {
        #if READER_OPEN_DIAGNOSTICS
        guard variants.contains(value) else { return }
        selection.lock.lock(); selection.selected = value; selection.lock.unlock()
        #endif
    }
    static var variant: String {
        #if READER_OPEN_DIAGNOSTICS
        selection.lock.lock(); defer { selection.lock.unlock() }; return selection.selected ?? argument("--reader-open-variant") ?? (roundTwo ? "async" : "both")
        #else
        "both"
        #endif
    }
    static var roundTwo: Bool { enabled && argument("--reader-open-round") == "2" }
    static var variants: [String] { roundTwo ? ["serial", "async"] : ["baseline", "wake", "display", "both"] }
    static func label(_ variant: String) -> String {
        switch variant { case "serial": "统计串行"; case "async": "统计异步"; case "baseline": "现状"; case "wake": "只改唤醒"; case "display": "只改显示"; default: "两项都改" }
    }
    static func displayedCounts() -> [String: Int] {
        #if READER_OPEN_DIAGNOSTICS
        recorder.counts()
        #else
        [:]
        #endif
    }
    static var serialStatistics: Bool {
        #if READER_OPEN_DIAGNOSTICS
        if roundTwo { return variant == "serial" }
        return ProcessInfo.processInfo.arguments.contains("--reader-open-serial-statistics")
        #else
        false
        #endif
    }
    static var wakes: Bool { roundTwo || variant == "both" || variant == "wake" }
    static var deferredPage: Bool { roundTwo || variant == "both" || variant == "display" }
    static func argument(_ key: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: key), a.indices.contains(i + 1) else { return nil }
        return a[i + 1]
    }
    static var gateDelay: TimeInterval {
        #if READER_OPEN_DIAGNOSTICS
        max(0, min(5000, Double(argument("--reader-open-delay-ms") ?? "0") ?? 0)) / 1000
        #else
        0
        #endif
    }
    static func begin(_ request: OpeningRequest) {
        #if READER_OPEN_DIAGNOSTICS
        recorder.begin(request)
        #endif
    }
    static func bind(_ bookID: String, to id: UUID) {
        #if READER_OPEN_DIAGNOSTICS
        recorder.bind(bookID, to: id)
        #endif
    }
    static func mark(_ id: UUID?, _ stage: String, span: UUID? = nil) {
        #if READER_OPEN_DIAGNOSTICS
        if let id { recorder.mark(id, stage, span: span) }
        #endif
    }
    static func worker(_ bookID: String, _ stage: String) {
        #if READER_OPEN_DIAGNOSTICS
        recorder.worker(bookID, stage)
        #endif
    }
    static func trace(_ attempt: UUID?) -> ReaderOpenTrace? { enabled ? ReaderOpenTrace(attempt: attempt) : nil }
    static func trace(book: String) -> ReaderOpenTrace? {
        #if READER_OPEN_DIAGNOSTICS
        trace(recorder.attempt(book))
        #else
        nil
        #endif
    }
    static func background(_ stage: String) {
        #if READER_OPEN_DIAGNOSTICS
        recorder.background(stage)
        #endif
    }
    #if READER_OPEN_DIAGNOSTICS
    private static let recorder = Recorder()
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [UUID: TimeInterval] = [:]
        private var variants: [UUID: String] = [:]
        private var roles: [UUID: String] = [:]
        private var displayed = Set<UUID>()
        private var books: [String: UUID] = [:]
        private var pending: [String: [(String, TimeInterval)]] = [:]
        private let writer = DispatchQueue(label: "moonread.open.diagnostics")
        private let log = OSLog(subsystem: "dev.moonread.Moonread", category: "ReaderOpen")
        private let destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("reader-open-events.jsonl")
        func begin(_ request: OpeningRequest) {
            lock.lock(); defer { lock.unlock() }
            attempts[request.id] = request.tap ?? request.routeRequested
            variants[request.id] = ReaderOpenDiagnostics.variant
            if case let .source(file) = request.target { roles[request.id] = file.shelfID.replacingOccurrences(of: "benchmark", with: "") }
            emit(request.id, "tap", at: attempts[request.id]!)
            emit(request.id, "fileReadable", at: request.routeRequested)
            emit(request.id, "routeRequested", at: request.routeRequested)
        }
        func bind(_ book: String, to id: UUID) {
            lock.lock(); defer { lock.unlock() }; books[book] = id
            for (stage,time) in pending.removeValue(forKey: book) ?? [] { emit(id, stage, at: time) }
        }
        func mark(_ id: UUID, _ stage: String, span: UUID?) {
            lock.lock(); defer { lock.unlock() }; emit(id, stage, at: ProcessInfo.processInfo.systemUptime, span: span)
        }
        func attempt(_ book: String) -> UUID? { lock.lock(); defer { lock.unlock() }; return books[book] }
        func background(_ stage: String) {
            let time = ProcessInfo.processInfo.systemUptime
            os_signpost(.event, log: log, name: "ReaderOpen", "background %{public}@", stage)
            write(["attempt":"background", "stage":stage, "uptime":time, "thread":pthread_mach_thread_np(pthread_self()), "mainThread":Thread.isMainThread])
        }
        func worker(_ book: String, _ stage: String) {
            lock.lock(); defer { lock.unlock() }; let time = ProcessInfo.processInfo.systemUptime
            if let id = books[book] { emit(id, stage, at: time) } else { pending[book, default: []].append((stage,time)) }
        }
        func counts() -> [String: Int] {
            lock.lock(); defer { lock.unlock() }
            var result: [String: Int] = [:]
            for id in displayed { result[(variants[id] ?? "both") + "-" + (roles[id] ?? "other"), default: 0] += 1 }
            return result
        }
        private func emit(_ id: UUID, _ stage: String, at time: TimeInterval, span: UUID? = nil) {
            guard let start = attempts[id] else { return }
            if stage == "bodyDisplayOpportunity" || stage == "coverDisplayOpportunity" { displayed.insert(id) }
            os_signpost(.event, log: log, name: "ReaderOpen", "%{public}@ %{public}@ %{public}@", id.uuidString, stage, span?.uuidString ?? "-")
            var value: [String: Any] = ["attempt":id.uuidString,"stage":stage,"uptime":time,"ms":(time-start)*1000,"variant":variants[id] ?? "both", "mode":ReaderOpenDiagnostics.argument("--reader-open-mode") ?? "resume", "role":roles[id] ?? "other"]
            value["span"] = span?.uuidString ?? "-"
            value["thread"] = pthread_mach_thread_np(pthread_self()); value["mainThread"] = Thread.isMainThread
            value["emittedUptime"] = ProcessInfo.processInfo.systemUptime
            write(value)
        }
        private func write(_ value: [String: Any]) {
            guard var bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
            bytes.append(10)
            let line = bytes, destination = self.destination
            writer.async {
                if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
                if let file = try? FileHandle(forWritingTo: destination) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: line) }
            }
        }
    }
    #endif
}

#if READER_OPEN_DIAGNOSTICS
import UIKit

@MainActor
final class ReaderDisplayProbe: NSObject {
    private weak var view: UIView?
    private let id: UUID
    private let cover: Bool
    private let glyphsVisible: () -> Bool
    private var link: CADisplayLink?
    private var first = false
    private var finished: (() -> Void)?
    init(view: UIView, id: UUID, cover: Bool, glyphsVisible: @escaping () -> Bool, finished: @escaping () -> Void) {
        self.view = view; self.id = id; self.cover = cover; self.glyphsVisible = glyphsVisible; self.finished = finished
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(frame)); self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func frame() {
        guard let view, let window = view.window else { stop(); return }
        guard UIApplication.shared.applicationState == .active,
              view.convert(view.bounds, to: window).intersects(window.bounds) else { return }
        var opacity: Float = 1
        var layer: CALayer? = view.layer
        while let current = layer { opacity *= current.presentation()?.opacity ?? current.opacity; layer = current.superlayer }
        guard opacity > 0.001, cover || glyphsVisible() else { return }
        if !first { first = true; ReaderOpenDiagnostics.mark(id, cover ? "coverDisplayOpportunity" : "bodyDisplayOpportunity") }
        if opacity >= 0.999 { ReaderOpenDiagnostics.mark(id, "fullyOpaqueOpportunity"); stop() }
    }
    private func stop() { link?.invalidate(); link = nil; let callback = finished; finished = nil; callback?() }
}
#endif

/// Correlates nested awaits without logging book identity or content.
struct ReaderOpenTrace: Sendable {
    let attempt: UUID?
    let span = UUID()
    func mark(_ stage: String) { ReaderOpenDiagnostics.mark(attempt, stage, span: span) }
}

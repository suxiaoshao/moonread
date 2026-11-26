import MoonreadData
import MoonreadCoreBindings
import Foundation
import SwiftUI

/// Serialize writes once; failed batches are discarded, never retried.
@MainActor @Observable
public final class StatisticsWriter {
    public static let shared = StatisticsWriter()
    private let save: @MainActor (ReadingSegmentBatch, ReadingLease) async throws -> Void
    private struct Write { var batch: ReadingSegmentBatch; let lease: ReadingLease }
    private var queued = [Write]()
    private var task: Task<Void, Never>?
    public private(set) var error: String?

    private init() {
        save = { batch, lease in try await lease.service.saveReadingSegments(batch) }
    }

    init(save: @escaping @MainActor (ReadingSegmentBatch) async throws -> Void) {
        self.save = { batch, _ in try await save(batch) }
    }

    func report(_ error: Error) { self.error = ReaderMessages.error(error) }

    func enqueue(_ values: [ReadingSegment], generation: UInt64, lease: ReadingLease) {
        guard !values.isEmpty else { return }
        let batch = ReadingSegmentBatch(bookID: lease.id, values: values, generation: generation, admission: lease.writeAdmission)
        if let last = queued.indices.last, queued[last].lease === lease, queued[last].batch.generation == generation {
            // Only queued, not yet started, locally generated revisions are
            // coalesced. Different IDs/visits keep their original order.
            var updates = queued[last].batch.values
            for value in values {
                if let existing = updates.last, existing.header.id == value.header.id,
                   existing.header.revision < value.header.revision, !existing.header.sealed {
                    updates[updates.count - 1] = value
                } else { updates.append(value) }
            }
            queued[last].batch = .init(bookID: batch.bookID, values: updates, generation: generation, admission: batch.admission)
        } else { queued.append(.init(batch: batch, lease: lease)) }
        guard task == nil else { return }
        task = Task { [self] in
            while !queued.isEmpty {
                let work = queued.removeFirst()
                do { try await save(work.batch, work.lease) }
                catch { report(error) }
                withExtendedLifetime(work.lease) {}
            }
            task = nil
        }
    }
    public func drain() async { await task?.value }
}

/// Injectable time keeps effective-duration tests on the real Rust reading clock.
struct ReadingActivityTime {
    let uptime: TimeInterval
    let date: Date
    #if DEBUG
    private static let fixtureStart = ProcessInfo.processInfo.systemUptime
    private static let acceleratedFixture: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-testing") && args.contains("--ui-test-session") && args.contains("--ui-test-review-prompt")
    }()
    #endif
    static func current() -> Self {
        let uptime = ProcessInfo.processInfo.systemUptime, date = Date()
        #if DEBUG
        if acceleratedFixture {
            // Only the isolated UI fixture advances time; it still obeys idle,
            // foreground and body-readability rules and must leave normally.
            return Self(uptime: uptime * 60, date: date.addingTimeInterval((uptime - fixtureStart) * 59))
        }
        #endif
        return Self(uptime: uptime, date: date)
    }
}

/// No timer state lives in a SwiftUI body. Only explicit body gestures refresh idle credit.
@MainActor
public final class ReadingActivityRecorder {
    private static weak var owner: ReadingActivityRecorder?
    private let preferences: @MainActor () async throws -> StatisticsPreferences
    private let writer: StatisticsWriter
    private let time: @MainActor () -> ReadingActivityTime
    private var startToken: UUID?
    private static var mutation: UUID?
    private var clock: ReadingSegmentState?
    private var author: ReadingSegmentAuthor?
    private let captureAuthor: @MainActor (ReadingLease) async throws -> ReadingSegmentAuthor
    private var lease: ReadingLease?
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var enabled = false
    private var stopped = false
    private var visibility = ReaderStatisticsVisibility(body: false)
    private var preview = false
    private var lastInteraction: TimeInterval = -.infinity
    private weak var viewport: ReadingViewportAccess?
    private var range: (UInt64, UInt64) = (0, 0)
    private(set) var effectiveReadingMilliseconds: UInt64 = 0

    convenience init(writer: StatisticsWriter = .shared, preferences: @escaping @MainActor () async throws -> StatisticsPreferences) { self.init(writer: writer, time: { .current() }, preferences: preferences) }

    init(writer: StatisticsWriter, time: @escaping @MainActor () -> ReadingActivityTime,
         captureAuthor: @escaping @MainActor (ReadingLease) async throws -> ReadingSegmentAuthor = { try await $0.service.readingSegmentAuthor($0) },
         preferences: @escaping @MainActor () async throws -> StatisticsPreferences) {
        self.writer = writer; self.time = time; self.preferences = preferences; self.captureAuthor = captureAuthor
    }

    /// Invalidates suspended starts before the next attempt is scheduled.
    func prepareStart(_ attempt: UUID) {
        guard !stopped else { return }
        visibility = ReaderStatisticsVisibility(body: false)
        endVisit()
        timer?.cancel(); timer = nil; clock = nil; author = nil; lease = nil; viewport = nil
        startToken = attempt
    }

    func start(lease: ReadingLease, viewport: ReadingViewportAccess, attempt: UUID) async {
        guard !stopped, !Task.isCancelled, startToken == attempt else { return }
        do {
            ReaderOpenDiagnostics.mark(attempt, "statisticsPreferences.queued")
            let capture = try await captureAuthor(lease)
            let value = try await preferences()
            ReaderOpenDiagnostics.mark(attempt, "statisticsPreferences.mainResumed")
            guard !stopped, !Task.isCancelled, startToken == attempt else { return }
            if Self.owner !== self { Self.owner?.stop(); Self.owner = self }
            self.lease = lease; self.viewport = viewport
            enabled = value.enabled; generation = value.generation
            // No clock exists while preferences are loading: never backdate reading.
            author = capture
            resetClock(newSession: false)
            sample()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    self?.sample()
                }
            }
        } catch {
            if !stopped, !Task.isCancelled, startToken == attempt { writer.report(error) }
        }
    }

    var recordingBookID: String? { clock == nil ? nil : lease?.id }
    var hasSamplingTimer: Bool { timer != nil }

    func update(visibility: ReaderStatisticsVisibility, preview: Bool) {
        self.visibility = visibility; self.preview = preview
        sample()
    }

    func interacted() {
        // Continuous drags can generate 120 callbacks/sec; these carry intent, not viewport samples.
        let now = time().uptime
        guard now - lastInteraction >= 0.25 else { return }
        lastInteraction = now
        sample(interaction: true, capture: false)
    }

    func breakVisit() { endVisit() }

    func flush() async {
        endVisit()
        await writer.drain()
    }

    @discardableResult
    private func endVisit(enqueue: Bool = true) -> [ReadingSegment] {
        guard Self.mutation == nil, let lease else { return [] }
        var values = observe()
        if let previous = clock {
            clock = nil
            do {
                let step = try breakReadingSegmentVisit(previous: previous, nextVisitId: UUID().uuidString.lowercased())
                clock = step.next
                values += step.segmentUpdates
            } catch { writer.report(error); resetClock() }
        }
        if enqueue { writer.enqueue(values, generation: generation, lease: lease) }
        return values
    }

    public struct Mutation: Sendable {
        public let id: UUID
        public let through: Int64
        public let batch: ReadingSegmentBatch?
        // Keep a departing reader alive until its final synchronous commit.
        let lease: ReadingLease?
    }

    public static func pauseForMutation(service: any ReaderDataAccess) async throws -> Mutation {
        guard mutation == nil else { throw CancellationError() }
        let id = UUID()
        let current = owner?.lease?.service === service ? owner : nil
        let lease = current?.lease
        let values = current?.endVisit(enqueue: false) ?? []
        let batch = if let current, let lease, !values.isEmpty {
            ReadingSegmentBatch(bookID: lease.id, values: values, generation: current.generation, admission: lease.writeAdmission)
        } else { nil as ReadingSegmentBatch? }
        mutation = id
        // Join already accepted writes outside the user's operation gate.
        await (current?.writer ?? .shared).drain()
        return .init(id: id, through: Int64(Date().timeIntervalSince1970 * 1000), batch: batch, lease: lease)
    }

    public static func finishMutation(_ id: UUID, preferences: StatisticsPreferences?) {
        guard mutation == id else { return }
        mutation = nil
        guard let owner, !owner.stopped else { return }
        if let preferences { owner.enabled = preferences.enabled; owner.generation = preferences.generation }
        owner.resetClock()
        owner.sample()
    }

    private func resetClock(newSession: Bool = true) {
        guard var author else { return }
        if newSession { author.sessionId = UUID().uuidString.lowercased(); self.author = author }
        do { clock = try beginReadingSegment(author: author, visitId: UUID().uuidString.lowercased(), limits: readingSegmentLimits()) }
        catch { writer.report(error) }
    }

    func bodyReadable(through readerViewport: ReadingViewportAccess? = nil) -> Bool {
        visibility.isReadable(nativeTaskPresented: (readerViewport ?? viewport)?.hasBlockingPresentation(
            allowingReaderAccessory: visibility.readerAccessoryPresented) ?? false)
    }

    func sample(interaction: Bool = false, capture: Bool = true) {
        guard let lease else { return }
        writer.enqueue(observe(interaction: interaction, capture: capture), generation: generation, lease: lease)
    }

    private func observe(interaction: Bool = false, capture: Bool = true) -> [ReadingSegment] {
        guard Self.mutation == nil, !stopped, let previous = clock else { return [] }
        let visible = capture ? viewport?.statisticsRange() : (range.1 > range.0 ? range : nil)
        if capture, let visible { range = visible }
        let instant = time(), now = instant.date
        clock = nil // Rust consumes the prior state, including on failure.
        do {
            let step = try advanceReadingSegment(previous: previous, moment: ReadingMoment(
                monotonicMs: UInt64(instant.uptime * 1000),
                unixMs: Int64(now.timeIntervalSince1970 * 1000),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now)),
                readable: enabled && bodyReadable() && visible != nil,
                interaction: interaction, automaticMoving: viewport?.controller?.autoReading?.running == true,
                automaticMilliseconds: viewport?.controller?.autoReading?.milliseconds ?? 0, preview: preview,
                startUtf8: range.0, endUtf8: range.1),
                segmentSeed: UUID().uuidString.lowercased(), nextVisitId: UUID().uuidString.lowercased())
            clock = step.next
            effectiveReadingMilliseconds += step.chargedDeltaMs
            return step.segmentUpdates
        } catch { writer.report(error); resetClock(); return [] }
    }

    func reloadPreferences() async {
        let token = startToken
        guard let preferences = try? await preferences(), !stopped, !Task.isCancelled, startToken == token,
              Self.mutation == nil, preferences.enabled != enabled || preferences.generation != generation else { return }
        enabled = preferences.enabled; generation = preferences.generation
        resetClock()
        sample()
    }

    func stop() {
        guard !stopped else { return }
        visibility = ReaderStatisticsVisibility(body: false); endVisit(); stopped = true
        startToken = nil
        timer?.cancel(); timer = nil; clock = nil; author = nil; lease = nil; viewport = nil
    }
}

/// Presentation facts only. The recorder/Rust clock retains credit and read kind.
struct ReaderStatisticsVisibility: Equatable {
    var body: Bool
    var preparingExcerpt = false
    var excerptPresented = false
    var confirmationPresented = false
    var choosingAnnotations = false
    var readerAccessoryPresented = false

    func isReadable(nativeTaskPresented: Bool = false) -> Bool {
        body && !preparingExcerpt && !excerptPresented && !confirmationPresented && !choosingAnnotations && !nativeTaskPresented
    }
}

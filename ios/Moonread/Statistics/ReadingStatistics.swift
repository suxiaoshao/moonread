import Foundation
import SwiftUI

extension ChapterEntry {
    var coverageLabel: String { coverageLabel(readingPrefix: true) }
    func coverageLabel(readingPrefix: Bool) -> String {
        guard countComplete, wordCount > 0, let coveredCharacters else { return "—" }
        if coveredCharacters > 0, coveredCharacters * 100 < wordCount {
            return readingPrefix ? String(localized: "已读不足 1%") : String(localized: "不足 1%")
        }
        let percentage = min(100, coveredCharacters * 100 / wordCount)
        return readingPrefix ? String(localized: "已读约 \(percentage)%") : String(localized: "约 \(percentage)%")
    }
    /// The chapter list's caption omits coverage only when a fully counted chapter has
    /// none recorded; unknown, partial and under-1% values keep their wording.
    var listCoverageLabel: String? {
        if countComplete, wordCount > 0, coveredCharacters == 0 { return nil }
        return coverageLabel
    }
}

extension Notification.Name {
    static let statisticsChanged = Notification.Name("Moonread.statisticsChanged")
    static let statisticsPreferencesChanged = Notification.Name("Moonread.statisticsPreferencesChanged")
}

extension AppDataService {
    func statisticsPreferences() -> StatisticsPreferences {
        ReaderOpenDiagnostics.background("statisticsPreferences.actor.begin"); defer { ReaderOpenDiagnostics.background("statisticsPreferences.actor.return") }
        return StatisticsPreferences(enabled: sourceDefaults.object(forKey: "Moonread.statisticsEnabled") as? Bool ?? true, generation: UInt64(sourceDefaults.integer(forKey: "Moonread.statisticsGeneration")))
    }
    func setStatisticsEnabled(_ enabled: Bool) async throws {
        try await changeReadingCapture(enabled: enabled)
    }

    func readingSegmentAuthor(_ lease: ReadingLease) async throws -> ReadingSegmentAuthor {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        guard lease.writeAdmission == index.lease else { throw CancellationError() }
        let owner = try index.session.readingInstallationID()
        try index.session.prepareReadingHistory(index.lease, owner: owner)
        return .init(ownerInstanceId: owner, sessionId: UUID().uuidString.lowercased(),
                     title: try index.readingCaptureTitle(bookID: lease.id), device: userDevice)
    }

    private func segmentAdmission(_ batch: ReadingSegmentBatch, index: ReaderIndex, preferences: StatisticsPreferences) -> Bool {
        preferences.enabled && batch.generation == preferences.generation && batch.admission == index.lease
    }

    func saveReadingSegments(_ batch: ReadingSegmentBatch) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let preferences = statisticsPreferences()
        let index = try relationalUserIndex()
        let keys = try index.writeReadingSegments([batch], owner: index.session.readingInstallationID()) {
            segmentAdmission($0, index: index, preferences: preferences)
        }
        guard !keys.isEmpty else { return }
        NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["keys": Array(keys)])
    }

    #if DEBUG
    // Synthetic released-history fixtures only. Production records segments.
    func saveReading(_ slices: [ReadingSlice], generation: UInt64, admission offered: DataSessionLease? = nil) async throws {
        guard !slices.isEmpty else { return }
        let admission = try offered ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let preferences = statisticsPreferences()
        let index = try relationalUserIndex()
        guard preferences.enabled, generation == preferences.generation, admission == index.lease else { return }
        let keys = try index.writeReadingFacts(slices, device: userDevice)
        guard !keys.isEmpty else { return }
        NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["keys": Array(keys)])
    }
    #endif
    func deleteStatistics(book: String? = nil, session: String? = nil) async throws {
        try await changeReadingCapture(clear: (book,session))
    }

    private func changeReadingCapture(enabled: Bool? = nil, clear: (String?,String?)? = nil) async throws {
        let configuration = userCloudConfigurationRevision
        let handoff = try await ReadingActivityRecorder.pauseForMutation(service: self)
        do {
            await acquireUserDataOperation()
            let next: StatisticsPreferences
            do {
                defer { releaseUserDataOperation() }
                try Task.checkCancellation()
                guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
                let previous = statisticsPreferences()
                let index = try relationalUserIndex(), owner = try index.session.readingInstallationID()
                if let (book, sessionID) = clear {
                    try index.clearReadingHistory(book: book, session: sessionID,
                        through: handoff.through, tail: handoff.batch.map { [$0] } ?? [], owner: owner) {
                        segmentAdmission($0, index: index, preferences: previous)
                    }
                } else if let batch = handoff.batch {
                    _ = try index.writeReadingSegments([batch], owner: owner) {
                        segmentAdmission($0, index: index, preferences: previous)
                    }
                }
                next = .init(enabled: enabled ?? previous.enabled, generation: previous.generation + 1)
                sourceDefaults.set(next.enabled, forKey: "Moonread.statisticsEnabled")
                sourceDefaults.set(Int(next.generation), forKey: "Moonread.statisticsGeneration")
                scheduleSystemWidgetStatistics(immediate: true)
                NotificationCenter.default.post(name: .statisticsPreferencesChanged, object: nil)
                NotificationCenter.default.post(name: .statisticsChanged, object: nil)
            }
            await ReadingActivityRecorder.finishMutation(handoff.id, preferences: next)
        } catch {
            await ReadingActivityRecorder.finishMutation(handoff.id, preferences: nil)
            throw error
        }
    }
}

/// Serialize writes once; failed batches are discarded, never retried.
@MainActor @Observable
final class StatisticsWriter {
    static let shared = StatisticsWriter()
    private let save: @MainActor (ReadingSegmentBatch, ReadingLease) async throws -> Void
    private struct Write { var batch: ReadingSegmentBatch; let lease: ReadingLease }
    private var queued = [Write]()
    private var task: Task<Void, Never>?
    private(set) var error: String?

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
    func drain() async { await task?.value }
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
final class ReadingActivityRecorder {
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

    convenience init(writer: StatisticsWriter = .shared, preferences: @escaping @MainActor () async throws -> StatisticsPreferences = {
        await AppDataService.shared.statisticsPreferences()
    }) { self.init(writer: writer, time: { .current() }, preferences: preferences) }

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

    struct Mutation: Sendable {
        let id: UUID
        let through: Int64
        let batch: ReadingSegmentBatch?
        // Keep a departing reader alive until its final synchronous commit.
        let lease: ReadingLease?
    }

    static func pauseForMutation(service: AppDataService) async throws -> Mutation {
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

    static func finishMutation(_ id: UUID, preferences: StatisticsPreferences?) {
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

enum StatisticsDates {
    static func systemReadingBounds(week: Bool, now: Date, calendar: Calendar) -> ClosedRange<Int64> {
        let today = day(now, calendar: calendar)
        let start = week ? calendar.dateInterval(of: .weekOfYear, for: now)!.start : now
        return day(start, calendar: calendar)...today
    }
    static var civilCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static func day(_ date: Date, calendar: Calendar = .current) -> Int64 {
        var local = Calendar(identifier: .gregorian); local.timeZone = calendar.timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return Int64((civilCalendar.date(from: parts) ?? date).timeIntervalSince1970 / 86_400)
    }
    static func date(_ day: Int64) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }
    static func dateLabel(_ day: Int64, full: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = civilCalendar; formatter.timeZone = civilCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(full ? "yMMMd" : "MMMd")
        return formatter.string(from: date(day))
    }
    /// A civil day number for a date already expressed in `civilCalendar`.
    static func civilDay(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
    static func format(_ day: Int64, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = civilCalendar; formatter.timeZone = civilCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date(day))
    }
    /// Dates within the current year omit the year; others keep it on both ends.
    static func rangeLabel(_ range: ClosedRange<Int64>, today: Int64) -> String {
        let year = { civilCalendar.component(.year, from: date($0)) }
        let full = year(range.lowerBound) != year(today) || year(range.upperBound) != year(today)
        if range.lowerBound == range.upperBound { return dateLabel(range.lowerBound, full: full) }
        return "\(dateLabel(range.lowerBound, full: full)) – \(dateLabel(range.upperBound, full: full))"
    }
    /// Round minute gridlines (10 minutes up to whole hours) covering the largest bar.
    static func axisSteps(_ maximum: Double) -> [Double] {
        let steps: [Double] = [5, 10, 15, 20, 30, 60, 120, 180, 240, 300, 600, 1200, 3000, 6000, 12000, 30000]
        let step = steps.first { maximum / $0 <= 3 } ?? (maximum / 3).rounded(.up)
        let count = Int((maximum / step).rounded(.up))
        return (0...max(1, count)).map { Double($0) * step }
    }
    static func duration(_ ms: UInt64) -> String {
        if ms == 0 { return String(localized: "0 分钟") }
        if ms < 60_000 { return String(localized: "不足 1 分钟") }
        let minutes = Int(ms / 60_000), hours = minutes / 60
        if hours == 0 { return String(localized: "\(minutes) 分钟") }
        return minutes % 60 == 0 ? String(localized: "\(hours) 小时") : String(localized: "\(hours) 小时 \(minutes % 60) 分钟")
    }
    static func clock(_ ms: Int64, offset: Int32) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.timeZone = TimeZone(secondsFromGMT: Int(offset))
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

#if DEBUG
extension AppDataService {
    /// Synthetic events live exclusively in the isolated UI-test store.
    func createStatisticsFixture(bookID: String? = nil) async throws {
        guard testSession != nil else { return }
        let core = try indexStore(), now = Date()
        guard try await statistics(first: 0, last: 100_000).books.isEmpty else { return }
        let entries = try core.sourceFiles(shelfId: "builtin").filter { $0.bookId != nil && (bookID == nil || $0.bookId == bookID) }.prefix(3)
        for (index, entry) in entries.enumerated() {
            guard let id = entry.bookId else { continue }
            for daysAgo in [0, 1, 3, 5, 9] {
                let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
                let start = Calendar.current.date(bySettingHour: 9 + index * 4, minute: 10, second: 0, of: day)!
                let count = 12 + index * 7 + daysAgo
                let clock = ReadingClock(bookId: id)
                var point = ReadingMoment(monotonicMs: 0, unixMs: Int64(start.timeIntervalSince1970 * 1000),
                    utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: start)), readable: true,
                    interaction: true, automaticMoving: false, automaticMilliseconds: 0, preview: false, startUtf8: 0, endUtf8: 30)
                _ = clock.update(moment: point)
                for minute in 1...count {
                    point.monotonicMs = UInt64(minute * 60_000)
                    point.unixMs = Int64(start.timeIntervalSince1970 * 1000) + Int64(minute * 60_000)
                    point.readable = minute != count
                    try await saveReading(clock.update(moment: point), generation: statisticsPreferences().generation)
                }
            }
        }
    }
}
#endif

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

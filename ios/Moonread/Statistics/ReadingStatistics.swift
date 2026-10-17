import Foundation
import SwiftUI

extension ChapterEntry {
    var coverageLabel: String {
        guard countComplete, wordCount > 0, let coveredCharacters else { return "—" }
        if coveredCharacters > 0, coveredCharacters * 100 < wordCount { return String(localized: "已读不足 1%") }
        return String(localized: "已读约 \(min(100, coveredCharacters * 100 / wordCount))%")
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

extension ReaderService {
    func statisticsPreferences() -> StatisticsPreferences {
        ReaderOpenDiagnostics.background("statisticsPreferences.actor.begin"); defer { ReaderOpenDiagnostics.background("statisticsPreferences.actor.return") }
        return StatisticsPreferences(enabled: sourceDefaults.object(forKey: "Moonread.statisticsEnabled") as? Bool ?? true, generation: UInt64(sourceDefaults.integer(forKey: "Moonread.statisticsGeneration")))
    }
    func setStatisticsEnabled(_ enabled: Bool) async throws {
        let generation = statisticsPreferences().generation + 1
        try await userStore().setRecording(generation: generation, enabled: enabled)
        try await userStore(pending: true).setRecording(generation: generation, enabled: enabled)
        sourceDefaults.set(enabled, forKey: "Moonread.statisticsEnabled")
        sourceDefaults.set(Int(generation), forKey: "Moonread.statisticsGeneration")
        NotificationCenter.default.post(name: .statisticsPreferencesChanged, object: nil)
    }
    func saveReading(_ slices: [ReadingSlice], generation: UInt64) async throws {
        let preferences = statisticsPreferences()
        var facts: [(String, String, String)] = [], pendingFacts: [(String, String, String)] = []
        for slice in slices {
            let key = try userKey(slice.bookId), book = try await snapshot(slice.bookId).book
            let value: [String: Any] = ["content_key": key, "title": book.title, "device": userDevice,
                "slice": try JSONSerialization.jsonObject(with: Data(encodeReadingSlice(value: slice).utf8))]
            let fact = (slice.id, key, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
            if key.hasPrefix("pending:") { pendingFacts.append(fact) } else { facts.append(fact) }
        }
        try await userStore().saveFacts(facts, generation: generation, current: preferences.generation, enabled: preferences.enabled)
        try await userStore(pending: true).saveFacts(pendingFacts, generation: generation, current: preferences.generation, enabled: preferences.enabled)
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
    }
    func statistics(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsOverview {
        try await effectiveQuery(facts: true).statisticsOverview(firstDay: first, lastDay: last, contentKey: book)
    }
    func activities(first: Int64, last: Int64, book: String? = nil) async throws -> [ReadingActivity] {
        try await effectiveQuery(facts: true).readingActivities(firstDay: first, lastDay: last, contentKey: book)
    }
    func deleteStatistics(book: String? = nil, session: String? = nil) async throws {
        let generation = statisticsPreferences().generation + 1
        try await userStore().clear(book: book, session: session, newGeneration: generation)
        try await userStore(pending: true).clear(book: book, session: session, newGeneration: generation)
        sourceDefaults.set(Int(generation), forKey: "Moonread.statisticsGeneration")
        NotificationCenter.default.post(name: .statisticsPreferencesChanged, object: nil)
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
    }
}

/// One bounded writer for all reader instances. Retries keep the same immutable slice IDs.
@MainActor @Observable
final class StatisticsWriter {
    static let shared = StatisticsWriter()
    private struct Batch {
        let slices: [ReadingSlice]
        let generation: UInt64
        let lease: ReadingLease // Keep a progressive identity alive until its final write.
    }
    private let save: @MainActor ([ReadingSlice], UInt64) async throws -> Void
    init(save: @escaping @MainActor ([ReadingSlice], UInt64) async throws -> Void = { slices, generation in
        try await ReaderService.shared.saveReading(slices, generation: generation)
    }) { self.save = save }
    private var queue: [Batch] = []
    private var task: Task<Void, Never>?
    private(set) var error: String?
    var isFull: Bool { queue.count >= 256 }
    func report(_ error: Error) { self.error = ReaderMessages.error(error) }

    func enqueue(_ slices: [ReadingSlice], generation: UInt64, lease: ReadingLease) {
        guard !slices.isEmpty else { return }
        queue.append(Batch(slices: slices, generation: generation, lease: lease))
        retry()
    }
    func retry() {
        guard task == nil else { return }
        task = Task { [self] in
            defer { task = nil }
            while let batch = queue.first {
                do {
                    try await save(batch.slices, batch.generation)
                    queue.removeFirst(); error = nil
                } catch { self.error = ReaderMessages.error(error); return }
            }
        }
    }
    func drain() async { await task?.value }
}

/// No timer state lives in a SwiftUI body. Only explicit body gestures refresh idle credit.
@MainActor
final class ReadingActivityRecorder {
    private static weak var owner: ReadingActivityRecorder?
    private let preferences: @MainActor () async throws -> StatisticsPreferences
    private let writer: StatisticsWriter
    private var startToken: UUID?
    private var clock: ReadingClock?
    private var lease: ReadingLease?
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var enabled = false
    private var stopped = false
    private var readable = false
    private var preview = false
    private var lastInteraction: TimeInterval = -.infinity
    private weak var viewport: ReadingViewportAccess?
    private var range: (UInt64, UInt64) = (0, 0)

    init(writer: StatisticsWriter = .shared, preferences: @escaping @MainActor () async throws -> StatisticsPreferences = {
        await ReaderService.shared.statisticsPreferences()
    }) { self.writer = writer; self.preferences = preferences }

    /// Invalidates suspended starts before the next attempt is scheduled.
    func prepareStart(_ attempt: UUID) {
        guard !stopped else { return }
        readable = false
        if clock != nil { sample() }
        timer?.cancel(); timer = nil; clock = nil; lease = nil
        startToken = attempt
    }

    func start(lease: ReadingLease, viewport: ReadingViewportAccess, attempt: UUID) async {
        guard !stopped, !Task.isCancelled, startToken == attempt else { return }
        do {
            ReaderOpenDiagnostics.mark(attempt, "statisticsPreferences.queued")
            let value = try await preferences()
            ReaderOpenDiagnostics.mark(attempt, "statisticsPreferences.mainResumed")
            guard !stopped, !Task.isCancelled, startToken == attempt else { return }
            if Self.owner !== self { Self.owner?.stop(); Self.owner = self }
            self.lease = lease; self.viewport = viewport
            enabled = value.enabled; generation = value.generation
            // No clock exists while preferences are loading: never backdate reading.
            clock = ReadingClock(bookId: lease.id)
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

    func update(readable: Bool, preview: Bool) {
        self.readable = readable; self.preview = preview
        sample()
    }

    func interacted() {
        // Continuous drags can generate 120 callbacks/sec; these carry intent, not viewport samples.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInteraction >= 0.25 else { return }
        lastInteraction = now
        sample(interaction: true, capture: false)
    }

    func breakVisit() {
        sample()
        guard let clock, let lease else { return }
        writer.enqueue(clock.breakVisit(), generation: generation, lease: lease)
    }

    func flush() async {
        sample()
        guard let clock, let lease else { return }
        // A tools panel has already paused the clock. Drain its final fact before querying coverage.
        writer.enqueue(clock.breakVisit(), generation: generation, lease: lease)
        await writer.drain()
    }

    private func sample(interaction: Bool = false, capture: Bool = true) {
        guard !stopped, let clock, let lease else { return }
        let writer = self.writer
        let visible = capture ? viewport?.controller?.statisticsRange() : (range.1 > range.0 ? range : nil)
        if capture, let visible { range = visible }
        let now = Date()
        let slices = clock.update(moment: ReadingMoment(
            monotonicMs: UInt64(ProcessInfo.processInfo.systemUptime * 1000),
            unixMs: Int64(now.timeIntervalSince1970 * 1000),
            utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now)),
            readable: enabled && readable && visible != nil && !writer.isFull,
            interaction: interaction, preview: preview, startUtf8: range.0, endUtf8: range.1))
        writer.enqueue(slices, generation: generation, lease: lease)
    }

    func reloadPreferences() async {
        sample()
        let token = startToken
        guard let preferences = try? await preferences(), !stopped, !Task.isCancelled, startToken == token else { return }
        enabled = preferences.enabled; generation = preferences.generation
        // A clear/pause starts a new recording session, never retries a pre-clear open interval.
        if let lease { clock = ReadingClock(bookId: lease.id) }
        sample()
    }

    func stop() {
        guard !stopped else { return }
        readable = false; sample(); stopped = true
        startToken = nil
        timer?.cancel(); timer = nil; clock = nil; lease = nil
    }
}

enum StatisticsDates {
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
    /// Compact chart axis values; exact durations are written elsewhere.
    static func axisMinutes(_ minutes: Double) -> String {
        if minutes <= 0 { return "0" }
        if minutes < 60 { return String(localized: "\(Int(minutes.rounded())) 分钟") }
        let hours = minutes / 60
        return hours.rounded() == hours ? String(localized: "\(Int(hours)) 小时") : String(localized: "\(hours.formatted(.number.precision(.fractionLength(1)))) 小时")
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
extension ReaderService {
    /// Synthetic events live exclusively in the isolated UI-test store.
    func createStatisticsFixture() async throws {
        guard testSession != nil else { return }
        let core = try textCore(), now = Date()
        guard try await statistics(first: 0, last: 100_000).books.isEmpty else { return }
        let entries = try core.sourceFiles(shelfId: "builtin").filter { $0.bookId != nil }.prefix(3)
        for (index, entry) in entries.enumerated() {
            guard let id = entry.bookId else { continue }
            for daysAgo in [0, 1, 3, 5, 9] {
                let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
                let start = Calendar.current.date(bySettingHour: 9 + index * 4, minute: 10, second: 0, of: day)!
                let count = 12 + index * 7 + daysAgo
                let clock = ReadingClock(bookId: id)
                var point = ReadingMoment(monotonicMs: 0, unixMs: Int64(start.timeIntervalSince1970 * 1000),
                    utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: start)), readable: true,
                    interaction: true, preview: false, startUtf8: 0, endUtf8: 30)
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

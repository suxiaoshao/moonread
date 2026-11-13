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
        let generation = statisticsPreferences().generation + 1
        try await userStore().setRecording(generation: generation, enabled: enabled)
        try await userStore(pending: true).setRecording(generation: generation, enabled: enabled)
        sourceDefaults.set(enabled, forKey: "Moonread.statisticsEnabled")
        sourceDefaults.set(Int(generation), forKey: "Moonread.statisticsGeneration")
        scheduleSystemReadingCatalog(statisticsChanged: true)
        NotificationCenter.default.post(name: .statisticsPreferencesChanged, object: nil)
    }
    func saveReading(_ slices: [ReadingSlice], generation: UInt64) async throws {
        let preferences = statisticsPreferences()
        var facts: [(String, String, String)] = [], pendingFacts: [(String, String, String)] = []
        var leases: [String: UUID] = [:]
        for slice in slices {
            let identity = try userKey(slice.bookId)
            let key = identity.storageKey
            leases[key] = localReadingWriteLease(key)
            let book = try await snapshot(slice.bookId).book
            let fact = (slice.id, key, try encodeReadingFact(contentKey: key, title: book.title, device: userDevice, slice: slice))
            switch identity { case .pending: pendingFacts.append(fact); case .formal: facts.append(fact) }
        }
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        facts = facts.filter { leases[$0.1] == localReadingWriteLease($0.1) }
        pendingFacts = pendingFacts.filter { leases[$0.1] == localReadingWriteLease($0.1) }
        try await userStore().saveFacts(facts, generation: generation, current: preferences.generation, enabled: preferences.enabled)
        try await userStore(pending: true).saveFacts(pendingFacts, generation: generation, current: preferences.generation, enabled: preferences.enabled)
        scheduleSystemReadingCatalog(statisticsChanged: true)
        NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["keys": Array(leases.keys)])
    }
    struct StatisticsRead<Value: Sendable>: Sendable {
        let value: Value
        let key: ReadingKey?
        let compatibilityNotice: String?
        let version: String
    }
    enum StatisticsResult<Value: Sendable>: Sendable {
        case identityPending(fileID: String)
        case ready(StatisticsRead<Value>)

        func requireReady() throws -> StatisticsRead<Value> {
            guard case .ready(let result) = self else { throw ReaderError.ImportBusy }
            return result
        }
    }
    private func statisticsTarget(book: String?) throws -> StatisticsTarget {
        try book.map { .book(.record(key: try parseReadingKey(value: $0))) } ?? .all
    }
    func statisticsQuery(first: Int64, last: Int64, book: String? = nil, fields: UserProjectionDomain = .metadata, scope: String = "statistics") async throws -> UserQueryOutput {
        try await statisticsQuery(first: first, last: last, target: statisticsTarget(book: book), fields: fields, scope: scope)
    }
    func statisticsQuery(first: Int64, last: Int64, target: StatisticsTarget, fields: UserProjectionDomain = .metadata, scope: String = "statistics") async throws -> UserQueryOutput {
        guard first <= last else { throw ReaderError.InvalidRange }
        let source: UserQuerySource = switch target {
        case .all: .fixed(records: .all, facts: .all)
        case .book(let book): .book(book, facts: true)
        }
        return try await readingQueryResult(source, options: .init(statisticsRange: first...last, scope: scope, fields: fields))
    }
    private func readStatistics<Value: Sendable>(first: Int64, last: Int64, target: StatisticsTarget,
        fields: UserProjectionDomain, project: @escaping @Sendable (ReaderQuery, ReadingKey?) throws -> Value) async throws -> StatisticsResult<Value> {
        let input = try await statisticsQuery(first: first, last: last, target: target, fields: fields)
        let key: ReadingKey?
        switch input.resolution {
        case .resolved(let record): key = record.key
        case .unidentified(let file): return .identityPending(fileID: file)
        case .missing: throw ReaderError.NotFound
        case nil: key = nil
        }
        let work = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try project(input.query, key)
        }
        let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return .ready(.init(value: value, key: key, compatibilityNotice: input.compatibilityNotice, version: input.statisticsVersion))
    }
    func statisticsRead(first: Int64, last: Int64, target: StatisticsTarget) async throws -> StatisticsResult<StatisticsOverview> {
        try await readStatistics(first: first, last: last, target: target, fields: .metadata) {
            try $0.statisticsOverview(firstDay: first, lastDay: last, contentKey: $1)
        }
    }
    func statisticsRead(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsRead<StatisticsOverview> {
        try await statisticsRead(first: first, last: last, target: statisticsTarget(book: book)).requireReady()
    }
    func statistics(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsOverview {
        try await statisticsRead(first: first, last: last, book: book).value
    }
    func activitiesRead(first: Int64, last: Int64, target: StatisticsTarget) async throws -> StatisticsResult<[ReadingActivity]> {
        try await readStatistics(first: first, last: last, target: target, fields: []) {
            try $0.readingActivities(firstDay: first, lastDay: last, contentKey: $1)
        }
    }
    func activitiesRead(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsRead<[ReadingActivity]> {
        try await activitiesRead(first: first, last: last, target: statisticsTarget(book: book)).requireReady()
    }
    func activities(first: Int64, last: Int64, book: String? = nil) async throws -> [ReadingActivity] {
        try await activitiesRead(first: first, last: last, book: book).value
    }
    func statisticsCompatibilityNotice(book: String? = nil) async throws -> String? {
        // Compatibility covers the whole resolved book/all-books scope, even
        // though this no-output request carries no history into Rust.
        try await statisticsQuery(first: 0, last: 0, book: book, fields: []).compatibilityNotice
    }
    func deleteStatistics(book: String? = nil, session: String? = nil) async throws {
        _ = try await statisticsCompatibilityNotice(book: book)
        let generation = statisticsPreferences().generation + 1
        try await userStore().clear(book: book, session: session, newGeneration: generation)
        try await userStore(pending: true).clear(book: book, session: session, newGeneration: generation)
        sourceDefaults.set(Int(generation), forKey: "Moonread.statisticsGeneration")
        scheduleSystemReadingCatalog(statisticsChanged: true)
        NotificationCenter.default.post(name: .statisticsPreferencesChanged, object: nil)
        scheduleSystemReadingCatalog(statisticsChanged: true)
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
    }
}

/// Serialize writes once; failed batches are discarded, never retried.
@MainActor @Observable
final class StatisticsWriter {
    static let shared = StatisticsWriter()
    private let save: @MainActor ([ReadingSlice], UInt64) async throws -> Void
    init(save: @escaping @MainActor ([ReadingSlice], UInt64) async throws -> Void = { slices, generation in
        try await AppDataService.shared.saveReading(slices, generation: generation)
    }) { self.save = save }
    private var task: Task<Void, Never>?
    private(set) var error: String?
    func report(_ error: Error) { self.error = ReaderMessages.error(error) }

    func enqueue(_ slices: [ReadingSlice], generation: UInt64, lease: ReadingLease) {
        guard !slices.isEmpty else { return }
        let previous = task
        task = Task { [self] in
            await previous?.value
            do { try await save(slices, generation) }
            catch { report(error) }
            // Keep the identity alive only through this attempt. Task completion
            // releases its captures on both success and failure.
            withExtendedLifetime(lease) { }
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
    private var clock: ReadingClock?
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
         preferences: @escaping @MainActor () async throws -> StatisticsPreferences) {
        self.writer = writer; self.time = time; self.preferences = preferences
    }

    /// Invalidates suspended starts before the next attempt is scheduled.
    func prepareStart(_ attempt: UUID) {
        guard !stopped else { return }
        visibility = ReaderStatisticsVisibility(body: false)
        if clock != nil { sample() }
        timer?.cancel(); timer = nil; clock = nil; lease = nil; viewport = nil
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

    func breakVisit() {
        sample()
        guard let clock, let lease else { return }
        enqueue(clock.breakVisit(), lease: lease)
    }

    func flush() async {
        sample()
        guard let clock, let lease else { return }
        // Explicit flush joins accepted writes. Display queries use breakVisit
        // without joining the writer; mandatory persistence boundaries keep this API.
        enqueue(clock.breakVisit(), lease: lease)
        await writer.drain()
    }

    func bodyReadable(through readerViewport: ReadingViewportAccess? = nil) -> Bool {
        visibility.isReadable(nativeTaskPresented: (readerViewport ?? viewport)?.hasBlockingPresentation(
            allowingReaderAccessory: visibility.readerAccessoryPresented) ?? false)
    }

    func sample(interaction: Bool = false, capture: Bool = true) {
        guard !stopped, let clock, let lease else { return }
        // UIKit can present/dismiss without a SwiftUI update. Every sampling
        // path (including capture:false interaction) reads the current chain.
        let visible = capture ? viewport?.statisticsRange() : (range.1 > range.0 ? range : nil)
        if capture, let visible { range = visible }
        let instant = time(), now = instant.date
        let slices = clock.update(moment: ReadingMoment(
            monotonicMs: UInt64(instant.uptime * 1000),
            unixMs: Int64(now.timeIntervalSince1970 * 1000),
            utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now)),
            readable: enabled && bodyReadable() && visible != nil,
            interaction: interaction, automaticMoving: viewport?.controller?.autoReading?.running == true,
            automaticMilliseconds: viewport?.controller?.autoReading?.milliseconds ?? 0, preview: preview, startUtf8: range.0, endUtf8: range.1))
        enqueue(slices, lease: lease)
    }

    private func enqueue(_ slices: [ReadingSlice], lease: ReadingLease) {
        effectiveReadingMilliseconds += slices.reduce(0) { total, slice in
            total + slice.exposures.reduce(0) { $0 + $1.durationMs }
        }
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
        visibility = ReaderStatisticsVisibility(body: false); sample(); stopped = true
        startToken = nil
        timer?.cancel(); timer = nil; clock = nil; lease = nil; viewport = nil
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
        let core = try textCore(), now = Date()
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

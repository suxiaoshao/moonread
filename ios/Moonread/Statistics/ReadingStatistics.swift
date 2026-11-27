import MoonreadDataTypes
import MoonreadReader
import MoonreadData
import MoonreadCoreBindings
import Foundation
import SwiftUI

extension Notification.Name {
    static let statisticsChanged = Notification.Name("Moonread.statisticsChanged")
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

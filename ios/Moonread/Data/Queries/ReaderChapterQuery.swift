import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

extension AppDataService {
    /// Run all SQL on the existing pool and compute only after the SQLite
    /// reader has returned. A new commit can be observed while Rust runs.
    private func coverageRead<T: Sendable>(_ configuration: UUID,
        _ read: () async throws -> T) async throws -> T {
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        let value = try await read()
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return value
    }

    private nonisolated static func coverageCPU<T: Sendable>(_ run: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try run()
        }
        let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return result
    }

    // Return the byte ranges only, so exposure strings are released before
    // loading endpoint text. Outer nil means the captured request is stale.
    private func coverageRanges(_ id: String, stamp: ChapterCoverageRead.Stamp, index: ReaderIndex,
        configuration: UUID) async throws -> [SourceSpan]?? {
        let rows = try await coverageRead(configuration) { try await index.chapterCoverageExposures(id, matching: stamp) }
        guard let rows else { return nil }
        return try await Self.coverageCPU { .some(try visibleDwellFromText(rows: rows)) }
    }

    private func makeCoverage(_ id: String, stamp: ChapterCoverageRead.Stamp, index: ReaderIndex,
        configuration: UUID) async throws -> ChapterOutline? {
        guard !stamp.unknownClear, !stamp.incomplete else { throw UserSyncCompatibilityError(statistics: true) }
        guard !stamp.outline.items.isEmpty else { return stamp.outline }
        guard let ranges = try await coverageRanges(id, stamp: stamp, index: index, configuration: configuration)
        else { return nil }
        let result: ChapterOutline
        if let ranges {
            let chunks = try await coverageRead(configuration) {
                try await index.chapterCoverageChunks(id, matching: stamp, ranges: ranges)
            }
            guard let chunks else { return nil }
            result = try await Self.coverageCPU {
                let counts = try chapterCoverageCounts(chunks: chunks, chapters: stamp.bounds)
                return ChapterCoverageRead.outline(stamp, counts: counts)
            }
        } else { result = stamp.outline }
        let latest = try await coverageRead(configuration) { try await index.chapterCoverageStamp(id) }
        return latest == stamp ? result : nil
    }

    func chapters(_ id: String) async throws -> ChapterOutline {
        let index = try relationalUserIndex(), configuration = userCloudConfigurationRevision
        let stamp = try await coverageRead(configuration) { try await index.chapterCoverageStamp(id) }
        guard let value = try await makeCoverage(id, stamp: stamp, index: index, configuration: configuration)
        else { throw ReaderError.SourceChanged }
        return value
    }

    /// Lifetime belongs to the visible consumer. A general table commit is
    /// only a wakeup: unchanged selected-book inputs don't restart Rust work.
    func observeChapterCoverage(_ id: String,
        receive: @escaping @MainActor @Sendable (Result<ChapterOutline?, Error>) -> Void) async throws {
        let index = try relationalUserIndex(), configuration = userCloudConfigurationRevision
        let events = try ChapterCoverageRead.events(index)
        var last: ChapterCoverageRead.Stamp?
        for try await _ in events {
            let current = try await coverageRead(configuration) { try await index.chapterCoverageStamp(id) }
            guard last != current else { continue }
            last = current
            await receive(.success(nil))
            do {
                let value = try await makeCoverage(id, stamp: current, index: index, configuration: configuration)
                if let value { await receive(.success(value)) }
            } catch is CancellationError { throw CancellationError() }
            catch { await receive(.failure(error)) }
        }
    }
}

extension AppDataService {
    func noteLocationDetails(_ id: String, offsets: [UInt64]) async throws -> [UInt64: (ChapterInfo?, Double?)] {
        try await fixedReaderRead { try $0.noteLocationDetails(id, offsets: offsets) }
    }
}

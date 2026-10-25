import Foundation
import ImageIO
import AppIntents

extension SystemReadingSnapshot {
    struct CoverThumbnail: Codable, Equatable, Sendable {
        let fileName: String
        let revision: String
        let pixelWidth: Int
        let pixelHeight: Int
    }
    struct Appearance: Codable, Equatable, Sendable {
        struct Tokens: Codable, Equatable, Sendable {
            let canvas: UInt32
            let paper: UInt32
            let ink: UInt32
            let secondary: UInt32
            let accent: UInt32
            let accentSurface: UInt32
            let onAccent: UInt32
            let border: UInt32
        }
        let light: Tokens?
        let dark: Tokens?
        var preferredDark: Bool? = nil
    }
    struct Statistics: Codable, Equatable, Sendable {
        struct Day: Codable, Equatable, Sendable { let localDay: Int64; let durationMs: UInt64 }
        /// Unknown statuses only degrade this block, never the entire catalogue.
        let status: String
        let generatedAt: Date
        let localDay: Int64
        let validUntil: Date
        let timeZoneID: String
        let calendarID: String
        let firstWeekday: Int
        let recordingEnabled: Bool
        var todayDurationMs: UInt64? = nil
        var weekDurationMs: UInt64? = nil
        var currentStreakDays: UInt64? = nil
        var days: [Day]? = nil
        func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
            date >= generatedAt && date < validUntil && calendar.isDate(date, inSameDayAs: generatedAt)
                && timeZoneID == calendar.timeZone.identifier && calendarID == String(describing: calendar.identifier)
                && firstWeekday == calendar.firstWeekday
        }
        func hasValues(at date: Date, calendar: Calendar = .current) -> Bool {
            status == "ready" && isCurrent(at: date, calendar: calendar)
                && todayDurationMs != nil && weekDurationMs != nil && currentStreakDays != nil && days?.count == 7
        }
    }
}

extension SystemReadingSnapshotFile {
    static let maximumCoverBytes = 256 * 1024
    var coversDirectory: URL { directory.appendingPathComponent("Covers", isDirectory: true) }
    func coverURL(_ cover: SystemReadingSnapshot.CoverThumbnail) -> URL? {
        let name = cover.fileName
        guard name.hasPrefix("cover-"), ["jpg", "png"].contains((name as NSString).pathExtension),
              !name.contains("/"), !name.contains("\\"), !name.contains(".."), name.utf8.count <= 160,
              (1...384).contains(cover.pixelWidth), (1...384).contains(cover.pixelHeight) else { return nil }
        return coversDirectory.appendingPathComponent(name)
    }
    func coverData(_ cover: SystemReadingSnapshot.CoverThumbnail) -> Data? {
        guard let url = coverURL(cover), let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, let size = values.fileSize, size <= Self.maximumCoverBytes,
              let data = try? Data(contentsOf: url), data.count <= Self.maximumCoverBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == cover.pixelWidth, height == cover.pixelHeight else { return nil }
        return data
    }
}

enum ReadingWidgetContent: String, AppEnum {
    case recent, book
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "小组件内容")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.recent: "最近阅读", .book: "指定书籍"]
}
struct ReadingWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "继续阅读"
    static let description = IntentDescription("选择最近阅读，或指定一本已识别的书。")
    @Parameter(title: "显示内容", default: .recent) var content: ReadingWidgetContent
    @Parameter(title: "书籍") var book: SystemBookEntity?
    static var parameterSummary: some ParameterSummary {
        When(\.$content, .equalTo, .book) {
            Summary("显示 \(\.$book)")
        } otherwise: {
            Summary("显示最近阅读")
        }
    }
}

extension SystemReadingWidgetModel {
    private struct DisplayBook: Equatable {
        let id: String; let title: String; let chapter: String?; let progress: Double?
        let availability: SystemReadingSnapshot.Availability; let cover: SystemReadingSnapshot.CoverThumbnail?
        init(_ book: SystemReadingSnapshot.Book) {
            id = book.id; title = book.title; chapter = book.chapterLabel; progress = book.progress
            availability = book.availability; cover = book.coverThumbnail
        }
    }
    static func reloadKinds(from previous: SystemReadingSnapshot?, to current: SystemReadingSnapshot) -> [String] {
        guard let previous, previous.storeScope == current.storeScope else { return [continueKind, recentKind, statisticsKind] }
        let themeChanged = previous.appearance != current.appearance
        var kinds: [String] = []
        if themeChanged || previous.recentIDs.first != current.recentIDs.first
            || previous.books.sorted(by: { $0.id < $1.id }).map(DisplayBook.init) != current.books.sorted(by: { $0.id < $1.id }).map(DisplayBook.init) { kinds.append(continueKind) }
        if themeChanged || recentBooks(in: previous, limit: 4).map(DisplayBook.init) != recentBooks(in: current, limit: 4).map(DisplayBook.init) { kinds.append(recentKind) }
        if themeChanged || !statisticsDisplayEqual(previous.statistics, current.statistics) { kinds.append(statisticsKind) }
        return kinds
    }
    private static func statisticsDisplayEqual(_ a: SystemReadingSnapshot.Statistics?, _ b: SystemReadingSnapshot.Statistics?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.status == b.status && a.localDay == b.localDay && a.validUntil == b.validUntil
            && a.timeZoneID == b.timeZoneID && a.calendarID == b.calendarID && a.firstWeekday == b.firstWeekday
            && a.recordingEnabled == b.recordingEnabled && a.todayDurationMs == b.todayDurationMs
            && a.weekDurationMs == b.weekDurationMs && a.currentStreakDays == b.currentStreakDays && a.days == b.days
    }
    static var sampleSnapshot: SystemReadingSnapshot {
        let now = Date(), calendar = Calendar.current
        let day = Int64((now.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: now))) / 86_400)
        let values: [UInt64] = [18, 32, 24, 47, 21, 50, 34]
        let statistics = SystemReadingSnapshot.Statistics(status: "ready", generatedAt: now, localDay: day,
            validUntil: calendar.dateInterval(of: .day, for: now)!.end, timeZoneID: calendar.timeZone.identifier,
            calendarID: String(describing: calendar.identifier), firstWeekday: calendar.firstWeekday, recordingEnabled: true,
            todayDurationMs: 34 * 60_000, weekDurationMs: 226 * 60_000, currentStreakDays: 7,
            days: values.enumerated().map { .init(localDay: day - 6 + Int64($0.offset), durationMs: $0.element * 60_000) })
        let titles = [sample.title, String(localized: "长街慢行"), String(localized: "海边邮局"), String(localized: "沿河而行")]
        let books = titles.enumerated().map { index, title in
            SystemReadingSnapshot.Book(id: SystemReadingLink.bookIDPrefix + String(repeating: String(index + 1), count: 64),
                title: title, author: nil, tags: [], availability: .available, sourceCount: 1, naturalOrdinal: UInt64(index),
                progress: [42, 18, 76, 9][index], chapterLabel: String(localized: "第十二章"), recentRank: UInt32(index), allowsAutomaticExposure: true)
        }
        return .init(storeScope: "synthetic-gallery", books: books, recentIDs: books.map(\.id), statistics: statistics)
    }
}

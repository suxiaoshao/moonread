import MoonreadStatisticsDates

public struct StatisticsSpan: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public enum Kind: String, Sendable { case fact, segment }

        let kind: Kind
        let recordID: String

        public init(kind: Kind, recordID: String) {
            self.kind = kind
            self.recordID = recordID
        }
    }

    public let id: ID
    let sessionID: String
    let key: String
    let title: String
    let day: Int64
    let offset: Int32
    let preview: Bool
    let start: Int64
    private(set) var end: Int64
    private(set) var milliseconds: UInt64

    public init(id: ID, sessionID: String, key: String, title: String, day: Int64,
                offset: Int32, preview: Bool, start: Int64, end: Int64, milliseconds: UInt64) {
        self.id = id
        self.sessionID = sessionID
        self.key = key
        self.title = title
        self.day = day
        self.offset = offset
        self.preview = preview
        self.start = start
        self.end = end
        self.milliseconds = milliseconds
    }

    public static func merge(_ spans: some Sequence<Self>, sum: ([UInt64]) throws -> UInt64) throws -> StatisticsTimeline {
        var result: [Self] = []
        var total: UInt64 = 0
        for span in spans {
            try Task.checkCancellation()
            total = try sum([total, span.milliseconds])
            if let prior = result.last, prior.sessionID == span.sessionID, prior.key == span.key,
               prior.day == span.day, prior.offset == span.offset, prior.preview == span.preview {
                let (gap, overflow) = span.start.subtractingReportingOverflow(prior.end)
                if !overflow, (-2...2).contains(gap) {
                    result[result.count - 1].end = span.end
                    result[result.count - 1].milliseconds = try sum([prior.milliseconds, span.milliseconds])
                    continue
                }
            }
            result.append(span)
        }
        return .init(spans: result, durationMs: total)
    }

    var startClock: Double { (Double(start) + Double(offset) * 1000 - Double(day) * 86_400_000) / 3_600_000 }
    var endClock: Double { (Double(end) + Double(offset) * 1000 - Double(day) * 86_400_000) / 3_600_000 }
    var time: String { "\(StatisticsDates.clock(start, offset: offset))–\(StatisticsDates.clock(end, offset: offset))" }
}

public struct StatisticsTimeline: Equatable, Sendable {
    let spans: [StatisticsSpan]
    let durationMs: UInt64
}

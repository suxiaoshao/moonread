import Foundation

/// The two sides of a deleted source interval share a display boundary.
enum TextAffinity { case upstream, downstream }

/// A finite display projection's sole coordinate map. Stored positions are UTF-8;
/// native layout and selection are UTF-16. Source coordinates here are relative to
/// the projection's sourceStart, never to the compressed string's byte count.
struct TextCoordinates: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let display: NSRange
        let source: Range<Int>
        let boundaries: [Int]
        var retained: Bool { display.length > 0 && !boundaries.isEmpty }
    }
    let segments: [Segment]
    private let retained: [Segment]
    let byteCount: Int
    let length: Int

    /// Explicit identity mapping, for standalone source excerpts (not reader views).
    init(_ text: String, leadingUTF16: Int = 0) {
        var values: [Segment] = []
        if leadingUTF16 > 0 { values.append(Segment(display: NSRange(location: 0, length: leadingUTF16), source: 0..<0, boundaries: [])) }
        let boundaries = Self.boundaries(text)
        values.append(Segment(display: NSRange(location: leadingUTF16, length: text.utf16.count), source: 0..<text.utf8.count, boundaries: boundaries))
        self.init(segments: values, byteCount: text.utf8.count, length: leadingUTF16 + text.utf16.count)
    }
    init(segments: [Segment], byteCount: Int, length: Int) {
        self.segments = segments; retained = segments.filter(\.retained); self.byteCount = byteCount; self.length = length
    }
    static func boundaries(_ text: String) -> [Int] {
        var values = [0], byte = 0
        for scalar in text.unicodeScalars {
            if scalar.utf16.count == 2 { values.append(byte) }
            byte += scalar.utf8.count; values.append(byte)
        }
        return values
    }
    func sourcePoint(_ display: Int, affinity: TextAffinity = .downstream) -> Int? {
        guard display >= 0, display <= length else { return nil }
        var low=0, high=retained.count
        while low<high {
            let mid=(low+high)/2, segment=retained[mid]
            let precedes = affinity == .downstream ? segment.display.location<=display : NSMaxRange(segment.display)<display
            if precedes { low=mid+1 } else { high=mid }
        }
        let index=affinity == .downstream ? low-1 : low
        guard retained.indices.contains(index) else { return nil }
        let segment=retained[index]
        guard display>=segment.display.location, display<=NSMaxRange(segment.display) else { return nil }
        return segment.source.lowerBound+segment.boundaries[display-segment.display.location]
    }
    /// Navigation chooses a retained character, highlighting uses displayRange instead.
    func displayPoint(_ source: Int, affinity: TextAffinity = .downstream) -> Int? {
        guard source >= 0, source <= byteCount else { return nil }
        var low=0, high=retained.count
        while low<high {
            let mid=(low+high)/2
            if retained[mid].source.lowerBound<=source { low=mid+1 } else { high=mid }
        }
        if low>0 {
            let segment=retained[low-1]
            if source<segment.source.upperBound {
                let target=source-segment.source.lowerBound
                var a=0, b=segment.boundaries.count
                while a<b { let mid=(a+b)/2; if segment.boundaries[mid]<target { a=mid+1 } else { b=mid } }
                var index=a<segment.boundaries.count && segment.boundaries[a]==target ? a : max(0,a-1)
                while index>0 && segment.boundaries[index-1]==segment.boundaries[index] { index-=1 }
                return segment.display.location+index
            }
            if source==byteCount && segment.source.upperBound==source { return NSMaxRange(segment.display) }
        }
        if affinity == .downstream {
            if low<retained.count { return retained[low].display.location }
            if let last=retained.last { return lastCharacter(last) }
        } else {
            if low>0 { return lastCharacter(retained[low-1]) }
            if let first=retained.first { return first.display.location }
        }
        return nil
    }
    private func lastCharacter(_ segment: Segment) -> Int {
        var index = max(0,segment.display.length-1)
        while index > 0 && segment.boundaries[index-1] == segment.boundaries[index] { index -= 1 }
        return segment.display.location+index
    }
    func sourceRange(_ range: NSRange) -> Range<Int>? {
        guard range.location >= 0, NSMaxRange(range) <= length,
              let start = sourcePoint(range.location, affinity: .downstream) else { return nil }
        if range.length == 0 { return start..<start }
        guard let end = sourcePoint(NSMaxRange(range), affinity: .upstream), start <= end else { return nil }
        return start..<end
    }
    /// Pure omitted-source hits deliberately produce no visible highlight.
    func displayRange(_ source: Range<Int>) -> NSRange? {
        guard source.lowerBound >= 0, source.upperBound <= byteCount else { return nil }
        var first: Int?, last: Int?
        var low=0, high=retained.count
        while low<high { let mid=(low+high)/2; if retained[mid].source.upperBound<=source.lowerBound { low=mid+1 } else { high=mid } }
        for segment in retained[low...] {
            if segment.source.lowerBound>=source.upperBound { break }
            let a=max(source.lowerBound,segment.source.lowerBound), b=min(source.upperBound,segment.source.upperBound)
            guard a<b, let start=displayPoint(a), let end=sourcePointToBoundary(b,segment:segment) else { continue }
            first=min(first ?? start,start); last=max(last ?? end,end)
        }
        guard let first, let last else { return nil }
        return NSRange(location: first, length: last - first)
    }
    private func sourcePointToBoundary(_ value: Int, segment: Segment) -> Int? {
        if value == segment.source.upperBound { return NSMaxRange(segment.display) }
        return displayPoint(value)
    }
    // Existing standalone excerpt callers use scalar rounding; reader callers use
    // optional point/range APIs so an out-of-window target cannot silently clamp.
    func utf8Offset(atUTF16 offset: Int) -> Int { sourcePoint(min(length, max(0, offset))) ?? 0 }
    func utf16Offset(atUTF8 offset: Int) -> Int { displayPoint(min(byteCount, max(0, offset))) ?? 0 }
}

/// Text and mapping are sliced/prefixed together; no view reconstructs a map from
/// compressed text. The source envelope includes proven omitted paragraphs.
struct ReadingText: Equatable, Sendable {
    let text: String
    let sourceStart: UInt64
    let sourceEnd: UInt64
    let coordinates: TextCoordinates
    let revision: UInt64
    var selectableRange: NSRange {
        guard let first = coordinates.segments.first(where: \.retained), let last = coordinates.segments.last(where: \.retained) else { return NSRange(location:0,length:0) }
        return NSRange(location:first.display.location,length:NSMaxRange(last.display)-first.display.location)
    }
    var firstVisibleOffset: UInt64? {
        coordinates.segments.first(where: \.retained).map { sourceStart + UInt64($0.source.lowerBound) }
    }
    init(text: String, sourceStart: UInt64 = 0) {
        self.text = text; self.sourceStart = sourceStart; sourceEnd = sourceStart + UInt64(text.utf8.count)
        coordinates = TextCoordinates(text); revision = 0
    }
    init(text: String, sourceStart: UInt64, sourceEnd: UInt64, coordinates: TextCoordinates, revision: UInt64 = 0) {
        self.text = text; self.sourceStart = sourceStart; self.sourceEnd = sourceEnd; self.coordinates = coordinates; self.revision = revision
    }
    init(_ window: ReadingWindow) {
        var text = "", segments: [TextCoordinates.Segment] = [], cursor = window.start, display = 0
        let ranges = (window.omitted.map { $0.startUtf8..<$0.endUtf8 } + window.paragraphs.filter { $0.kind == .blank }.map { $0.startUtf8..<$0.endUtf8 }).sorted { $0.lowerBound < $1.lowerBound }
        var confirmed: [Range<UInt64>] = []
        for range in ranges {
            if let last=confirmed.last, last.upperBound>=range.lowerBound { confirmed[confirmed.count-1]=last.lowerBound..<max(last.upperBound,range.upperBound) }
            else { confirmed.append(range) }
        }
        func omitted(_ from: UInt64, _ to: UInt64) -> TextCoordinates.Segment {
            var low=0, high=confirmed.count
            while low<high { let mid=(low+high)/2; if confirmed[mid].upperBound<=from { low=mid+1 } else { high=mid } }
            precondition(low<confirmed.count && confirmed[low].lowerBound<=from && confirmed[low].upperBound>=to,"Only confirmed blank source ranges may be omitted")
            return .init(display:NSRange(location:display,length:0),source:Int(from-window.start)..<Int(to-window.start),boundaries:[])
        }
        for chunk in window.chunks {
            let blanks = window.paragraphs.filter { $0.kind == .blank && $0.endUtf8 > chunk.startUtf8 && $0.startUtf8 < chunk.endUtf8 }
            var source = chunk.startUtf8
            let bytes = Array(chunk.text.utf8)
            func append(_ start: UInt64, _ end: UInt64) {
                guard start < end else { return }
                if cursor < start { segments.append(omitted(cursor,start)) }
                guard let value = String(bytes:bytes[Int(start-chunk.startUtf8)..<Int(end-chunk.startUtf8)],encoding:.utf8) else { preconditionFailure("Source span must preserve UTF8 scalar boundaries") }
                let length = value.utf16.count
                segments.append(.init(display: NSRange(location: display, length: length), source: Int(start-window.start)..<Int(end-window.start), boundaries: TextCoordinates.boundaries(value)))
                text += value; display += length; cursor = end
            }
            for blank in blanks {
                let a = max(source, blank.startUtf8), b = min(chunk.endUtf8, blank.endUtf8)
                append(source, a); source = b
            }
            append(source, chunk.endUtf8)
        }
        if cursor < window.end { segments.append(omitted(cursor,window.end)) }
        self.init(text: text, sourceStart: window.start, sourceEnd: window.end,
                  coordinates: TextCoordinates(segments: segments,byteCount: Int(window.end-window.start),length: display),revision:window.revision)
    }
    func prefixed(_ prefix: String) -> ReadingText {
        let n = prefix.utf16.count
        let values = [TextCoordinates.Segment(display: NSRange(location:0,length:n),source:0..<0,boundaries:[])] + coordinates.segments.map { .init(display:NSRange(location:$0.display.location+n,length:$0.display.length),source:$0.source,boundaries:$0.boundaries) }
        return ReadingText(text:prefix+text,sourceStart:sourceStart,sourceEnd:sourceEnd,coordinates:.init(segments:values,byteCount:coordinates.byteCount,length:n+coordinates.length),revision:revision)
    }
    /// Ownership boundaries use the next retained source start (gaps belong to
    /// the preceding page; leading/trailing gaps belong to the first/last page).
    func slice(_ range: NSRange) -> ReadingText {
        precondition(range.location >= 0 && NSMaxRange(range) <= coordinates.length)
        let start = range.location == 0 ? 0 : (coordinates.sourcePoint(range.location) ?? 0)
        let end = NSMaxRange(range) == coordinates.length ? coordinates.byteCount : (coordinates.sourcePoint(NSMaxRange(range)) ?? coordinates.byteCount)
        var values: [TextCoordinates.Segment] = []
        for segment in coordinates.segments {
            let overlap = NSIntersectionRange(segment.display,range)
            if segment.retained && overlap.length > 0 {
                let local = overlap.location-segment.display.location
                let a = segment.source.lowerBound+segment.boundaries[local], b = segment.source.lowerBound+segment.boundaries[local+overlap.length]
                let boundaries = segment.boundaries[local...local+overlap.length].map { $0-segment.boundaries[local] }
                values.append(.init(display:NSRange(location:overlap.location-range.location,length:overlap.length),source:(a-start)..<(b-start),boundaries:boundaries))
            } else if !segment.retained && segment.display.length == 0 && segment.source.upperBound > start && segment.source.lowerBound < end {
                values.append(.init(display:NSRange(location:max(0,segment.display.location-range.location),length:0),source:(max(start,segment.source.lowerBound)-start)..<(min(end,segment.source.upperBound)-start),boundaries:[]))
            } else if segment.boundaries.isEmpty && overlap.length > 0 {
                values.append(.init(display:NSRange(location:overlap.location-range.location,length:overlap.length),source:0..<0,boundaries:[]))
            }
        }
        return ReadingText(text:(text as NSString).substring(with:range),sourceStart:sourceStart+UInt64(start),sourceEnd:sourceStart+UInt64(end),coordinates:.init(segments:values,byteCount:end-start,length:range.length),revision:revision)
    }
}

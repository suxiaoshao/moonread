import Foundation
import MoonreadCoreBindings

public extension ChapterEntry {
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

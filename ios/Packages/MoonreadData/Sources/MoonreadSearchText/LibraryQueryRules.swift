import Foundation
import NaturalLanguage

/// Shares the same named metadata matching owner as in-App library queries.
/// It can run in an extension using only the already-produced catalogue.
public enum LibraryQueryRules {
    /// The system's default Mandarin reading, shared by library and system search.
    /// No dictionary or polyphonic alternatives; keep conventional keyboard lü → lv.
    public static func pinyinSpellings(_ text: String) -> [String] {
        let latin = NSMutableString(string: text)
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        latin.setString((latin as String).decomposedStringWithCanonicalMapping)
        latin.replaceOccurrences(of: "u\u{0308}", with: "v", options: .literal, range: NSRange(location: 0, length: latin.length))
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        let syllables = (latin as String).lowercased().split { !$0.isLetter && !$0.isNumber }
        return [syllables.joined(), String(syllables.compactMap(\.first))].filter { $0.count > 1 }
    }

    /// Platform search vocabulary only; no novel text or AI matching profile.
    /// Entity selection and Spotlight share metadata vocabulary. The system's
    /// own Spotlight matching policy is independent of our EntityStringQuery.
    static let systemMetadataTermLimit = 64
    public static func systemMetadataTerms(title: String, author: String?, tags: [String]) -> [String] {
        let names = [title, author ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var terms = names, words: [String] = []
        for text in names {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = String(text[range])
                if word.count > 1, word.contains(where: { $0.isLetter || $0.isNumber }) { words.append(word) }
                return true
            }
            terms += pinyinSpellings(text)
        }
        // Keep full names and their pinyin ahead of potentially long token/tag
        // lists, so the bound cannot discard the Entity query's pinyin keys.
        terms += words + tags
        var seen = Set<String>()
        return Array(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(systemMetadataTermLimit))
    }
}

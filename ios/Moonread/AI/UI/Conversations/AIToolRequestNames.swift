import MoonreadCoreBindings
import AISDKProvider
import Foundation
import MoonreadAI

/// Display names already established by earlier committed tools within this turn.
struct AIToolRequestNames: Equatable {
    var references: [String: String] = [:]
    var chapterAtPosition: String?
    subscript(_ reference: String?) -> String? { reference.flatMap { references[$0] } }

    static func preceding(_ items: [AIProcessItem]) -> [String: Self] {
        var history: [String: String] = [:]
        var chapters: [String: [String: AIChapterResult]] = [:]
        var result: [String: Self] = [:]

        func remember(_ ref: String?, _ name: String?) {
            if let ref, let name, !name.isEmpty { history[ref] = name }
        }
        func file(_ value: JSONValue) {
            let entry = value.object
            remember(entry["ref"]?.string, entry["name"]?.string)
            remember(entry["fileRef"]?.string, entry["name"]?.string)
            if let book = entry["bookRef"]?.string, history[book] == nil { remember(book, entry["name"]?.string) }
        }
        func book(_ value: JSONValue) {
            for source in value.object["files"]?.array ?? [] { file(source) }
            remember(value.object["bookRef"]?.string, value.object["title"]?.string)
            remember(value.object["fileRef"]?.string, value.object["title"]?.string)
            remember(value.object["ref"]?.string, value.object["title"]?.string)
        }

        func record(_ item: AIProcessItem) {
            guard let output = item.output,
                  ["ok", "partial"].contains(output.object["status"]?.string ?? "") else { return }
            let data = output.object["data"] ?? .null
            let rows = data.object["items"]?.array ?? []
            switch item.name {
            case "list_shelf": rows.forEach(file)
            case "find_books", "show_books": rows.forEach(book)
            case "get_book_info": book(data)
            case "list_chapters":
                if let bytes = try? JSONEncoder().encode(data), let saved = try? JSONDecoder().decode(AIChaptersResult.self, from: bytes) {
                    for chapter in saved.items {
                        remember(chapter.chapterRef, chapter.title)
                        chapters[saved.bookRef, default: [:]][chapter.chapterRef] = chapter
                    }
                }
            case "list_marks":
                // A single mark arrives in items; older single-mark results were the data itself.
                for mark in data.object["items"] == nil ? [data] : rows {
                    let fields = mark.object
                    remember(fields["markRef"]?.string, AIToolResultDetails.snippet(fields["noteText"]?.string ?? fields["note"]?.string ?? fields["excerpt"]?.string))
                    for variant in fields["variants"]?.array ?? [] {
                        remember(variant.object["variantRef"]?.string, AIToolResultDetails.snippet(variant.object["noteSnippet"]?.string))
                    }
                }
            case "generate_image":
                for image in data.object["attachments"]?.array ?? [] {
                    remember(image.object["attachmentRef"]?.string, String(localized: "生成的图片"))
                }
            case "search_cover":
                for cover in data.object["candidates"]?.array ?? [] {
                    remember(cover.object["attachment"]?.object["attachmentRef"]?.string, String(localized: "候选封面"))
                }
            default: break
            }
            for source in AIWebSource.committed(in: output, tool: item.name) { remember(source.id, source.title) }
            for source in output.object["sources"]?.array ?? [] {
                remember(source.object["sourceRef"]?.string, source.object["title"]?.string)
            }
        }

        let saved: [(sequence: Int, item: AIProcessItem)] = items.compactMap { item in
            item.resultSequence.map { (sequence: $0, item: item) }
        }
        var pending = saved.sorted { $0.sequence < $1.sequence }[...]
        for item in items where item.kind == .tool {
            // Tool calls in one assistant entry may run in parallel. Only use
            // outputs persisted before this request, regardless of completion order.
            while let saved = pending.first, saved.sequence < (item.callSequence ?? .max) {
                record(saved.item)
                pending = pending.dropFirst()
            }
            let input = item.input.object
            let referenceKeys = ["bookRef", "fileRef", "chapterRef", "parentRef", "scopeRef", "markRef", "variantRef", "attachmentRef"]
            var values = referenceKeys.compactMap { input[$0]?.string }
            for key in ["bookRefs", "sourceRefs", "refs"] { values += input[key]?.array?.compactMap(\.string) ?? [] }
            for placement in input["placements"]?.array ?? [] {
                values += ["fileRef", "parentRef"].compactMap { placement.object[$0]?.string }
            }
            if let ref = input["rename"]?.object["fileRef"]?.string { values.append(ref) }
            var names = Self()
            for ref in values { names.references[ref] = history[ref] }
            let books = input["bookRefs"]?.array ?? []
            if let book = input["bookRef"]?.string ?? (books.count == 1 ? books.first?.string : nil),
               let offset = ["around", "at", "near"].lazy.compactMap({ input[$0]?.string.flatMap(AIPosition.offset(of:)) }).first,
               let saved = chapters[book] {
                let matches = saved.values.filter { chapter in
                    chapter.level != 0 && chapter.range.startUtf8 <= offset && offset < chapter.range.endUtf8
                }
                if matches.count == 1 { names.chapterAtPosition = matches.first?.title }
            }
            if names != Self() { result[item.id] = names }
        }
        return result
    }
}

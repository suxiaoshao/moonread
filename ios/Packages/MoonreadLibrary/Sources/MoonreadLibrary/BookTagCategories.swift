import Foundation

/// Display-only grouping of complete tags. A tag always keeps its stored text.
enum BookTagCategory: String, CaseIterable, Decodable, Identifiable {
    case fiction, plot, world, relationship, character, narrative, setting
    case subject, form, origin, ending, audience, content, uncategorized

    var id: Self { self }

    var title: String {
        switch self {
        case .fiction: String(localized: "小说类型")
        case .plot: String(localized: "情节与套路")
        case .world: String(localized: "世界设定")
        case .relationship: String(localized: "关系与配对")
        case .character: String(localized: "人物")
        case .narrative: String(localized: "叙事与基调")
        case .setting: String(localized: "时代与场景")
        case .subject: String(localized: "主题与学科")
        case .form: String(localized: "体裁与形式")
        case .origin: String(localized: "创作来源与同人")
        case .ending: String(localized: "结局")
        case .audience: String(localized: "读者与频道")
        case .content: String(localized: "内容要素与提示")
        case .uncategorized: String(localized: "未归类")
        }
    }

    static func category(for name: String) -> Self {
        guard let map else { return .uncategorized }
        if let category = map.terms[Data(name.utf8)] { return category }
        for (prefix, category) in prefixes where name.hasPrefix(prefix) {
            if !name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return category
            }
        }
        return .uncategorized
    }

    static func groups(_ tags: [BookTagChoice]) -> [BookTagGroup] {
        let grouped = Dictionary(grouping: tags, by: \.category)
        return (map?.order ?? [.uncategorized]).compactMap { category in
            guard let tags = grouped[category] else { return nil }
            return BookTagGroup(category: category, tags: tags.sorted(by: tagPrecedes))
        }
    }

    private static let pinyin = Locale(identifier: "zh_Hans_CN@collation=pinyin")

    private static func tagPrecedes(_ lhs: BookTagChoice, _ rhs: BookTagChoice) -> Bool {
        if lhs.bookCount != rhs.bookCount { return lhs.bookCount > rhs.bookCount }
        let order = lhs.name.compare(rhs.name, options: [], locale: pinyin)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.lexicographicallyPrecedes(rhs.id)
    }

    private static let prefixes: [(String, Self)] = [
        ("Fandom: ", .origin), ("Character: ", .character), ("Relationship: ", .relationship)
    ]

    private struct TagMap: Decodable {
        let version: Int
        let groupOrder: [BookTagCategory]
        let termToGroup: [String: BookTagCategory]
    }

    private static let map: (order: [Self], terms: [Data: Self])? = {
        guard let url = Bundle.module.url(forResource: "tag-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode(TagMap.self, from: data),
              map.version == 1, map.groupOrder.count == allCases.count,
              Set(map.groupOrder) == Set(allCases)
        else { return nil }
        // Swift String equality is canonical-equivalent; candidate tags match exact UTF-8.
        return (map.groupOrder, Dictionary(uniqueKeysWithValues: map.termToGroup.map { (Data($0.key.utf8), $0.value) }))
    }()
}

struct BookTagChoice: Identifiable {
    let name: String
    let bookCount: Int
    let category: BookTagCategory
    var id: Data { Data(name.utf8) }
}

struct BookTagGroup: Identifiable {
    let category: BookTagCategory
    let tags: [BookTagChoice]
    var id: BookTagCategory { category }
}

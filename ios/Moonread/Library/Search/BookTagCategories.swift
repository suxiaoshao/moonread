import Foundation

/// Display-only grouping of complete tags. A tag always keeps its stored text.
enum BookTagCategory: CaseIterable, Identifiable {
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
        if let category = terms[Data(name.utf8)] { return category }
        for (prefix, category) in prefixes where name.hasPrefix(prefix) {
            if !name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return category
            }
        }
        return .uncategorized
    }

    static func groups(_ tags: [BookTagChoice]) -> [BookTagGroup] {
        let grouped = Dictionary(grouping: tags, by: \.category)
        return allCases.compactMap { category in
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

    /// Reviewed whole terms and explicitly paired spellings from the taxonomy.
    private static let terms = Dictionary(uniqueKeysWithValues: allCases.flatMap { category in
        category.reviewedTerms.map { (Data($0.utf8), category) }
    })

    private var reviewedTerms: [String] {
        switch self {
        case .fiction:
            ["仙侠", "武侠", "玄幻", "奇幻", "西幻", "西方奇幻", "科幻", "科學幻想小說", "Science Fiction",
             "硬科幻", "太空歌剧", "都市高武", "体育竞技", "军事小说", "战争小说", "历史军事", "历史演义",
             "悬疑推理", "推理小说", "女频悬疑", "言情", "古代言情", "现实题材", "赛博朋克小说"]
        case .plot:
            ["升级流", "升級流", "领主经营", "基建", "争霸", "破案", "种田", "种田文", "穿书", "重生",
             "快穿", "无限流", "异世界转生"]
        case .world:
            ["机甲", "星际", "末世", "废土", "灵气复苏", "魔法", "修仙体系", "系统流", "ABO", "赛博朋克"]
        case .relationship:
            ["战友情", "师徒", "青梅竹马", "先婚后爱", "年下", "BL", "GL", "无CP", "M/M", "F/F"]
        case .character:
            ["剑修", "飞行员", "侦探", "勇者", "反派", "女强", "女主", "双女主", "非人主角"]
        case .narrative:
            ["第一人称", "群像", "多视角", "书信体", "轻松", "治愈", "甜文", "热血", "慢热", "黑色幽默"]
        case .setting:
            ["唐代", "民国", "维多利亚时代", "校园", "职场", "朝堂", "军营", "近未来", "二战"]
        case .subject:
            ["女性成长", "代际关系", "太空探索", "足球", "电子竞技", "社会学", "心理学", "中国史", "自然科学",
             "计算机科学", "军事史", "农业史", "科技史"]
        case .form:
            ["轻小说", "短篇", "长篇", "合集", "散文", "诗歌", "传记", "口述史", "报告文学", "科普读物"]
        case .origin:
            ["原创", "同人", "综漫", "跨作品联动", "原作向", "Alternate Universe", "影视改编"]
        case .ending:
            ["HE", "BE", "开放结局", "多结局", "Happy Ending"]
        case .audience:
            ["男频", "女频", "全年龄向", "儿童读物", "青少年读物", "Young Adult"]
        case .content:
            ["R-18", "R-18G", "图像化暴力描写", "主要角色死亡", "无适用警告", "作者选择不作警告"]
        case .uncategorized:
            []
        }
    }
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

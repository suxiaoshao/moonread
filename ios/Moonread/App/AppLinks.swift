import Foundation

/// Published policy/support URLs, reviewed before publication.
enum AppLinks {
    static let site = URL(string: "https://suxiaoshao.github.io/moonread/")!
    static func privacy(language: String = Locale.current.language.languageCode?.identifier ?? "en") -> URL {
        page("privacy", language: language)
    }
    static func support(language: String = Locale.current.language.languageCode?.identifier ?? "en") -> URL {
        page("support", language: language)
    }
    static let writeReview = URL(string: "https://apps.apple.com/app/id6823849812?action=write-review")!
    static let supportEmail = "suxiaoshao@gmail.com"
    static var contact: URL? { URL(string: "mailto:" + supportEmail) }
    private static func page(_ path: String, language: String) -> URL {
        site.appendingPathComponent((language == "zh" ? "" : "en/") + path + "/")
    }
    static func providerPrivacy(_ provider: String) -> URL? {
        let links = ["openai": "https://openai.com/policies/privacy-policy/", "anthropic": "https://www.anthropic.com/legal/privacy", "google": "https://policies.google.com/privacy", "xai": "https://x.ai/legal/privacy-policy", "openrouter": "https://openrouter.ai/privacy"]
        return links[provider].flatMap(URL.init(string:))
    }
}

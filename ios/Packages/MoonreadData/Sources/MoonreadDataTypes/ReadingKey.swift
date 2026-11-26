import MoonreadCoreBindings

public extension ReadingKey {
    var storageKey: String { serializeReadingKey(key: self) }
    var formalSHA256: String? {
        if case .formal(let sha256) = self { return sha256 }
        return nil
    }
}

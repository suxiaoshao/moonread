import MoonreadCoreBindings

public enum StatisticsTarget: Hashable, Sendable {
    case all, book(BookTarget)
    case books(Set<String>)
}

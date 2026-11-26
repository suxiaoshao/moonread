import Foundation

extension Notification.Name {
    public static let statisticsPreferencesChanged = Notification.Name("Moonread.statisticsPreferencesChanged")
    public static let cloudDataReceived = Notification.Name("Moonread.cloudDataReceived")
    public static let bookMetadataChanged = Notification.Name("Moonread.bookMetadataChanged")
    public static let cloudReadingPositionsReceived = Notification.Name("Moonread.cloudReadingPositionsReceived")
    public static let readingContinuationInvalidated = Notification.Name("Moonread.readingContinuationInvalidated")
}

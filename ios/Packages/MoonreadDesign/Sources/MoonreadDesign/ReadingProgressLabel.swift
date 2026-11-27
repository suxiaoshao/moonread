import Foundation

public enum ReadingProgressLabel {
    public static func text(needsDownload: Bool, fraction: Double?) -> String {
        if needsDownload { return String(localized: "待下载") }
        guard let fraction else { return String(localized: "未读") }
        return fraction.formatted(.percent.precision(.fractionLength(1)))
    }
}

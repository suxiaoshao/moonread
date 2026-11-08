import CoreText
import Observation
import UIKit

/// Known Apple document fonts only: never enumerate the user's installed fonts.
/// Downloaded fonts are system-managed, not private ReaderFonts resources.
@MainActor @Observable
final class ReaderBuiltinFonts {
    static let shared = ReaderBuiltinFonts()
    static let changed = Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)
    private(set) var revision = 0
    private var available: Set<ReaderFont> = []
    @ObservationIgnored private let lookup: @MainActor (String, CGFloat) -> UIFont?
    @ObservationIgnored private let match: @MainActor ([String]) -> AsyncThrowingStream<Double, Error>

    init(lookup: @escaping @MainActor (String, CGFloat) -> UIFont? = ReaderBuiltinFonts.installedFont,
         match: @escaping @MainActor ([String]) -> AsyncThrowingStream<Double, Error> = ReaderFontDownload.match) {
        self.lookup = lookup; self.match = match
        refresh()
    }
    // PostScript IDs, not family/display-name guesses (Apple system font catalog).
    private static func names(_ font: ReaderFont) -> (body: String, heading: String)? {
        switch font {
        case .system: nil
        case .serif: (SystemInstalledFont.songtiName, "STSongti-SC-Bold")
        case .rounded: ("STYuanti-SC-Regular", "STYuanti-SC-Bold")
        }
    }
    /// Confirm the requested face also supplies Chinese glyphs, rather than
    /// accepting a Western base face whose Chinese is entirely cascade fallback.
    private static func installedFont(_ name: String, size: CGFloat) -> UIFont? {
        SystemInstalledFont.lookup(name, size: size)
    }
    func refresh() {
        let next = Set([ReaderFont.serif, .rounded].filter { font in
            Self.names(font).map { lookup($0.body, 20) != nil } ?? false
        })
        if next != available { available = next; revision += 1 }
    }
    func isAvailable(_ font: ReaderFont) -> Bool { font == .system || available.contains(font) }
    func font(_ choice: ReaderFont, size: CGFloat, heading: Bool) -> UIFont? {
        guard let names = Self.names(choice), isAvailable(choice) else { return nil }
        // A missing Bold must not silently change the heading's Chinese family.
        return (heading ? lookup(names.heading, size) : nil) ?? lookup(names.body, size)
    }
    func prepare(_ font: ReaderFont, progress: (Double) -> Void) async throws {
        refresh()
        guard !isAvailable(font), let names = Self.names(font) else { return }
        // Download the required body face. Existing Bold is used for headings;
        // otherwise headings use the same family's regular face, at heading size.
        // https://developer.apple.com/documentation/technologyoverviews/fonts
        for try await value in match([names.body]) {
            try Task.checkCancellation()
            progress(value)
        }
        try Task.checkCancellation()
        refresh()
        guard isAvailable(font) else { throw ReaderBuiltinFontError.unavailable }
    }
}

private enum ReaderBuiltinFontError: LocalizedError {
    case unavailable
    var errorDescription: String? { String(localized: "字体下载未完成，请检查网络后重试。原字体保持不变。") }
}

private enum ReaderFontDownload {
    /// Core Text invokes this on a private serial queue. Keep the callback
    /// explicitly Sendable, and send only scalar progress/errors to MainActor.
    nonisolated static func match(_ names: [String]) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = Cancellation()
            continuation.onTermination = { @Sendable _ in cancellation.cancel() }
            let descriptors = names.map { CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary) }
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { @Sendable state, parameters in
                guard !cancellation.cancelled else { return false }
                let values = parameters as NSDictionary
                switch state {
                case .downloading:
                    if let value = values[kCTFontDescriptorMatchingPercentage] as? NSNumber, value.doubleValue.isFinite {
                        continuation.yield(min(1, max(0, value.doubleValue / 100)))
                    }
                case .didFinish: continuation.finish()
                case .didFailWithError:
                    let error = values[kCTFontDescriptorMatchingError] as? NSError
                    continuation.finish(throwing: error ?? ReaderBuiltinFontError.unavailable)
                    return false
                default: break
                }
                return true
            }
            if !started { continuation.finish(throwing: ReaderBuiltinFontError.unavailable) }
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }
}

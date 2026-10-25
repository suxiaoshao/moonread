import Foundation
import StoreKit
import SwiftUI
import UIKit

/// Uses the same civil-day IDs and effective milliseconds as reading statistics.
enum ReadingReviewEligibility {
    static let minimumReadingMilliseconds: UInt64 = 5 * 60 * 1_000
    static let minimumInterval: TimeInterval = 120 * 24 * 60 * 60

    static func allows(days: [StatisticsDay], milliseconds: UInt64, version: String,
                       requestedVersions: Set<String>, lastRequest: Date?, now: Date) -> Bool {
        guard milliseconds >= minimumReadingMilliseconds, !version.isEmpty,
              Set(days.filter { $0.durationMs > 0 }.map(\.day)).count >= 3 else { return false }
        return historyAllows(version: version, requestedVersions: requestedVersions, lastRequest: lastRequest, now: now)
    }

    static func historyAllows(version: String, requestedVersions: Set<String>, lastRequest: Date?, now: Date) -> Bool {
        !version.isEmpty && !requestedVersions.contains(version)
            && (lastRequest.map { now.timeIntervalSince($0) >= minimumInterval } ?? true)
    }
}

/// One device-local record, never passed to the user-data/CloudKit stores.
@MainActor final class ReadingReviewStore {
    static let key = "Moonread.readingReview.requests.v1"
    private struct History: Codable {
        var requestedVersions: Set<String> = []
        var lastRequest: Date? = nil
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var history: History? {
        if let data = defaults.data(forKey: Self.key) { return try? JSONDecoder().decode(History.self, from: data) }
        return defaults.object(forKey: Self.key) == nil ? History() : nil
    }
    func mayRequest(version: String, now: Date = Date()) -> Bool {
        guard let history else { return false }
        return ReadingReviewEligibility.historyAllows(version: version, requestedVersions: history.requestedVersions, lastRequest: history.lastRequest, now: now)
    }

    /// Claim before calling StoreKit: it doesn't report whether a prompt was shown.
    /// An unreadable record fails closed, without overwriting unknown/newer data.
    func claim(days: [StatisticsDay], milliseconds: UInt64, version: String, now: Date = Date()) -> Bool {
        guard var history else { return false }
        guard ReadingReviewEligibility.allows(days: days, milliseconds: milliseconds, version: version,
            requestedVersions: history.requestedVersions, lastRequest: history.lastRequest, now: now) else { return false }
        history.requestedVersions.insert(version); history.lastRequest = now
        guard let data = try? JSONEncoder().encode(history) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}

struct ReadingReviewCandidate: Equatable {
    let id = UUID()
    let milliseconds: UInt64
}

/// A one-shot opportunity created by a completed reader exit, never by opening
/// a page or returning to the foreground. Busy/error/navigation changes skip it.
@MainActor struct ReadingReviewAfterReading: ViewModifier {
    let library: LibraryModel
    @Environment(ThemeStore.self) private var themes
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    private let store: ReadingReviewStore

    init(library: LibraryModel) {
        self.library = library
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-session"), args.indices.contains(index + 1),
           let defaults = UserDefaults(suiteName: "Moonread.ReviewTests." + args[index + 1]) {
            store = ReadingReviewStore(defaults: defaults)
        } else { store = ReadingReviewStore() }
        #else
        store = ReadingReviewStore()
        #endif
    }

    func body(content: Content) -> some View {
        content.onChange(of: phase) { _, phase in
            if phase != .active { library.reviewCandidate = nil }
        }.task(id: library.reviewCandidate?.id) {
            guard let candidate = library.reviewCandidate else { return }
            defer { if library.reviewCandidate?.id == candidate.id { library.reviewCandidate = nil } }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--ui-testing"), !args.contains("--ui-test-review-prompt") { return }
            #endif
            guard isBookshelf, candidate.milliseconds >= ReadingReviewEligibility.minimumReadingMilliseconds,
                  let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  store.mayRequest(version: version) else { return }
            let returnPath = library.libraryPath
            // Let the native pop and final-save UI settle; never block navigation.
            do {
                try await Task.sleep(for: .seconds(1))
                guard canPresent, library.libraryPath == returnPath else { return }
                let overview = try await AppDataService.shared.statistics(first: 0, last: StatisticsDates.day(Date()))
                guard !Task.isCancelled, canPresent, library.libraryPath == returnPath,
                      store.claim(days: overview.days, milliseconds: candidate.milliseconds, version: version) else { return }
                requestReview()
            } catch { /* Missing statistics or cancellation must never interrupt reading. */ }
        }
    }

    // Native menus/alerts and interactive transitions aren't all represented by
    // library routes. Check public presentation state before claiming a request.
    private var presentationIsIdle: Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).filter(\.isKeyWindow)
        return !windows.isEmpty && windows.allSatisfy { window in
            guard window.windowLevel == .normal, let root = window.rootViewController else { return false }
            return Self.isIdle(root)
        }
    }
    private static func isIdle(_ controller: UIViewController) -> Bool {
        controller.presentedViewController == nil && controller.transitionCoordinator == nil
            && controller.children.allSatisfy(isIdle)
    }

    private var canPresent: Bool {
        guard phase == .active, Onboarding.shared.completed, themes.error == nil,
              library.selectedTab == .library, library.openingFileID == nil, !library.busy,
              library.error == nil, library.readerExitError == nil,
              library.sheet == nil, library.aiRequest == nil, !library.filePickerPresented,
              library.pendingDecision == nil, library.deletion == nil, library.removingShelf == nil, presentationIsIdle else { return false }
        return isBookshelf
    }

    private var isBookshelf: Bool {
        guard library.selectedTab == .library else { return false }
        switch library.libraryPath.last {
        case nil, .folder, .allBooks, .recent: return true
        default: return false
        }
    }
}

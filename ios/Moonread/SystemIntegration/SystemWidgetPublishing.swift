import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import WidgetKit

struct SystemReadingDerivedCover: Sendable {
    let reference: SystemReadingSnapshot.CoverThumbnail
    let data: Data
    static func encode(_ image: CGImage, sha: String, pixels: Int) -> Self? {
        guard image.width <= pixels, image.height <= pixels, pixels <= 384 else { return nil }
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, (alpha ? UTType.png : .jpeg).identifier as CFString, 1, nil) else { return nil }
        // Encoding decoded pixels rather than source properties strips EXIF/GPS.
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(output), data.length <= SystemReadingSnapshotFile.maximumCoverBytes else { return nil }
        return .init(reference: .init(fileName: "cover-\(sha)-r1-\(pixels).\(alpha ? "png" : "jpg")", revision: "r1-" + sha,
                                     pixelWidth: image.width, pixelHeight: image.height), data: data as Data)
    }
}

extension SystemReadingSnapshotFile {
    static let coverBudget = 32 * 1024 * 1024
    func publishCover(_ value: SystemReadingDerivedCover) throws {
        guard let target = coverURL(value.reference), value.data.count <= Self.maximumCoverBytes else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        if !FileManager.default.fileExists(atPath: target.path) {
            try value.data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func cleanupCovers(current: Set<String>, previous: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: coversDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { return }
        var keep = current
        var used = urls.filter { keep.contains($0.lastPathComponent) }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where previous.contains(url.lastPathComponent) && !keep.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Self.coverBudget
            if used + size <= Self.coverBudget { keep.insert(url.lastPathComponent); used += size }
        }
        for url in urls where url.lastPathComponent.hasPrefix("cover-") && !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    }
}

extension AppDataService {
    func systemDerivedCover(_ cover: BookCoverAsset) async -> SystemReadingDerivedCover? {
        for pixels in [384, 274, 192] {
            guard !Task.isCancelled else { return nil }
            guard let image = try? await coverImage(cover, pixels: pixels), let cgImage = image.cgImage else { continue }
            let value = await Task.detached(priority: .utility) { SystemReadingDerivedCover.encode(cgImage, sha: cover.sha256, pixels: pixels) }.value
            if let value, value.data.count <= 128 * 1024 || pixels == 192 { return value }
        }
        return nil
    }
    /// Configuration lookup is independent of publication: a slow/failed system
    /// request cannot prevent the App from publishing a usable catalogue.
    func refreshSystemWidgetConfigurations() {
        guard libraryDirectoryOverride == nil, testSession == nil, let scope = systemCatalog?.scope else { return }
        Task { [weak self] in
            let ids: [String]? = await Self.configuredSystemWidgetBooks()
            guard let ids else { return }
            await self?.acceptSystemWidgetConfigurations(ids, scope: scope)
        }
    }
    @MainActor private static func configuredSystemWidgetBooks() async -> [String]? {
        guard let values = try? await WidgetCenter.shared.currentConfigurations() else { return nil }
        return values.compactMap { info in
            let configuration = info.widgetConfigurationIntent(of: ReadingWidgetConfiguration.self)
            return configuration?.content == .book ? configuration?.book?.id : nil
        }
    }
    private func acceptSystemWidgetConfigurations(_ ids: [String], scope: String) {
        guard systemCatalog?.scope == scope, systemCatalog?.configuredBooks != ids else { return }
        systemCatalog?.configuredBooks = ids; scheduleSystemReadingCatalog()
    }
    func refreshSystemWidgetCalendarIfNeeded() {
        if let statistics = systemCatalog?.displaySnapshot?.statistics, !statistics.isCurrent(at: Date()) {
            scheduleSystemReadingCatalog(statisticsChanged: true)
        }
    }
    func systemWidgetAppearance() async -> SystemReadingSnapshot.Appearance? {
        guard let value = try? await themes() else { return nil }
        let preferredDark: Bool? = switch value.preferences.appMode { case .system: nil; case .light: false; case .dark: true }
        guard let light = try? resolveThemes(value: value, system: .light, highContrast: false).app,
              let dark = try? resolveThemes(value: value, system: .dark, highContrast: false).app else { return nil }
        return await MainActor.run {
            func tokens(_ plan: ResolvedTheme) -> SystemReadingSnapshot.Appearance.Tokens {
                let theme = ThemeSurface(plan: plan)
                return .init(canvas: theme.canvas.opaqueRGB, paper: theme.paper.opaqueRGB, ink: theme.ink.opaqueRGB,
                             secondary: theme.secondary.opaqueRGB, accent: theme.accent.opaqueRGB,
                             accentSurface: theme.accentSurface.opaqueRGB, onAccent: theme.onAccent.opaqueRGB, border: theme.border.opaqueRGB)
            }
            return .init(light: light.colors == nil ? nil : tokens(light), dark: dark.colors == nil ? nil : tokens(dark), preferredDark: preferredDark)
        }
    }
    func systemWidgetStatistics(now: Date = Date(), calendar: Calendar = .current) async -> SystemReadingSnapshot.Statistics {
        let today = StatisticsDates.day(now, calendar: calendar)
        let until = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let enabled = statisticsPreferences().enabled
        func result(_ status: String, summary: StatisticsWidgetSummary? = nil) -> SystemReadingSnapshot.Statistics {
            .init(status: status, generatedAt: now, localDay: today, validUntil: until,
                  timeZoneID: calendar.timeZone.identifier, calendarID: String(describing: calendar.identifier), firstWeekday: calendar.firstWeekday, recordingEnabled: enabled,
                  todayDurationMs: summary?.todayDurationMs, weekDurationMs: summary?.weekDurationMs,
                  currentStreakDays: summary?.currentStreakDays, days: summary?.days.map { .init(localDay: $0.day, durationMs: $0.durationMs) })
        }
        do {
            if try await statisticsCompatibilityNotice() != nil { return result("incomplete") }
            let week = StatisticsDates.systemReadingBounds(week: true, now: now, calendar: calendar)
            let query = try await effectiveQuery(facts: true, scope: "system-widget-statistics")
            let summary = try await Task.detached(priority: .utility) { try query.statisticsWidgetSummary(today: today, weekStart: week.lowerBound) }.value
            return result(!enabled && !summary.hasReadingHistory ? "notEnabled" : "ready", summary: summary)
        } catch let error as UserSyncCompatibilityError where error.reason == .newerFormat { return result("incomplete") }
        catch { return result("unavailable") }
    }
}

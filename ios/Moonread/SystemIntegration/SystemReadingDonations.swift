@preconcurrency import AppIntents
import Foundation
import WidgetKit

extension AppDataService {
    /// Independent, bounded platform consumers. After a suspension each
    /// chain uses the latest published envelope, rather than queueing one
    /// task and holding one catalogue for every revision.
    func systemReadingSnapshotPublished(_ snapshot: SystemReadingSnapshot) {
        guard libraryDirectoryOverride == nil, testSession == nil, systemSnapshotIsCurrent(snapshot) else { return }
        if systemSpotlightTask == nil {
            systemSpotlightTask = Task { [weak self] in await self?.submitLatestSystemSpotlight() }
        }
        if systemExposureTask == nil {
            systemExposureTask = Task { [weak self] in await self?.submitLatestSystemExposure() }
        }
    }

    private func submitLatestSystemSpotlight() async {
        defer { systemSpotlightTask = nil }
        var submitted: UUID?
        while let snapshot = systemCatalog?.displaySnapshot, snapshot.generation != submitted, !Task.isCancelled {
            submitted = snapshot.generation
            do { try await reconcileSystemSpotlight(snapshot) }
            catch {
                if systemSnapshotIsCurrent(snapshot) {
                    reportSystemSpotlightProgress(String(localized: "系统搜索提交失败，请重试。"))
                    recordSystemExposureError(error)
                }
            }
        }
    }

    private func submitLatestSystemExposure() async {
        defer { systemExposureTask = nil }
        var submitted: UUID?
        while let snapshot = systemCatalog?.displaySnapshot, snapshot.generation != submitted, !Task.isCancelled {
            submitted = snapshot.generation
            guard await requestSystemWidgetReload(snapshot) else { continue }
            // Siri revoke remains ordered, independent of Spotlight.
            await reconcileSystemReadingDonations(snapshot)
            await donatePendingSystemReading(snapshot)
        }
    }

    @discardableResult
    func requestSystemWidgetReload(_ snapshot: SystemReadingSnapshot,
        using reload: @MainActor @Sendable ([String]) -> Void = { kinds in
            for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }) async -> Bool {
        guard systemSnapshotIsCurrent(snapshot) else { return false }
        let kinds = SystemReadingWidgetModel.reloadKinds(from: systemWidgetReloadSnapshot, to: snapshot)
            .filter { $0 != SystemReadingWidgetModel.statisticsKind }
        if !kinds.isEmpty {
            await reload(kinds)
            // A skipped publication never advances this comparison baseline.
            // Record requests, not assumptions about WidgetKit's later display.
            systemWidgetReloadSnapshot = snapshot
        }
        return true
    }

    func systemSnapshotIsCurrent(_ snapshot: SystemReadingSnapshot) -> Bool {
        systemCatalog?.scope == snapshot.storeScope && systemCatalog?.publishedGeneration == snapshot.generation
    }
    private func recordSystemExposureError(_ error: Error) {
        systemReadingLastError = Self.systemReadingRefreshMessage(error)
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
    }
    func clearLegacyDonations() async throws {
        try await IntentDonationManager.shared.deleteDonations(matching: .intentType(OpenSystemBookIntent.self))
    }
    private func reconcileSystemReadingDonations(_ snapshot: SystemReadingSnapshot) async {
        guard systemCatalog?.scope == snapshot.storeScope else { return }
        do {
            let index = try indexStore()
            var state = try index.systemSubmission("siri")
            if state.scope != snapshot.storeScope {
                try await IntentDonationManager.shared.deleteDonations(matching: .intentType(OpenSystemBookIntent.self))
                state = .init(scope: snapshot.storeScope)
                try index.saveSystemSubmission("siri", state: state)
            }
            let allowed = Set(snapshot.books.filter(\.allowsAutomaticExposure).map(\.id))
            for id in state.ids where !allowed.contains(id) {
                try await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifier(EntityIdentifier(for: SystemBookEntity.self, identifier: id)))
                state.ids.removeAll { $0 == id }
                try index.saveSystemSubmission("siri", state: state)
            }
        } catch {
            // IDs remain recorded until a revoke succeeds; next foreground/publication retries.
            // Optional system suggestions never block reading or modify user facts.
            recordSystemExposureError(error)
        }
    }
    func systemReadingBegan(_ bookID: String) {
        guard libraryDirectoryOverride == nil, testSession == nil, systemCatalog?.accountPending == false,
              case .formal(let sha) = try? userKey(bookID) else { return }
        // Only the latest actually opened book needs a suggestion. A reader
        // never waits for a catalogue, thumbnail or platform callback.
        systemCatalog?.pendingDonation = SystemReadingLink.bookIDPrefix + sha
        scheduleSystemReadingCatalog()
    }

    private func donatePendingSystemReading(_ snapshot: SystemReadingSnapshot) async {
        guard systemSnapshotIsCurrent(snapshot), systemCatalog?.accountPending == false,
              let target = systemCatalog?.pendingDonation else { return }
        systemCatalog?.pendingDonation = nil
        guard let book = snapshot.books.first(where: { $0.id == target && $0.allowsAutomaticExposure }) else { return }
        await donateSystemReading(book, scope: snapshot.storeScope)
    }

    private func donateSystemReading(_ book: SystemReadingSnapshot.Book, scope: String) async {
        let policy = systemExposurePolicy()
        guard policy.systemSearchEnabled, systemCatalog?.scope == scope, systemCatalog?.accountPending == false,
              let snapshot = systemCatalog?.displaySnapshot, snapshot.exposurePolicy == policy,
              snapshot.books.contains(where: { $0.id == book.id && $0.allowsAutomaticExposure }) else { return }
        do {
            let index = try indexStore()
            var state = try index.systemSubmission("siri")
            guard state.scope == scope else { return } // A failed old-scope revocation must finish first.
            // Record before awaiting the system, so an interrupted donation can still be revoked.
            if !state.ids.contains(book.id) { state.ids.append(book.id); try index.saveSystemSubmission("siri", state: state) }
            _ = try await IntentDonationManager.shared.donate(intent: OpenSystemBookIntent(target: .init(book: book)))
            if systemCatalog?.scope != scope || systemCatalog?.accountPending == true || systemExposurePolicy() != policy {
                try await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifier(EntityIdentifier(for: SystemBookEntity.self, identifier: book.id)))
            }
        } catch { recordSystemExposureError(error) }
    }
}

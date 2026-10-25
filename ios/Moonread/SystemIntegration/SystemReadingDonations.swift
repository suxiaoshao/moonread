@preconcurrency import AppIntents
import Foundation

private struct SystemReadingDonationState: Codable {
    var schemaVersion = 1
    var scope: String
    var bookIDs: [String] = []
}

extension AppDataService {
    /// One platform work chain keeps revoke/donate ordering explicit without
    /// making the App's storage actor wait for system services.
    func systemReadingSnapshotPublished(_ snapshot: SystemReadingSnapshot) {
        guard libraryDirectoryOverride == nil, testSession == nil else { return }
        let previous = systemExposureTask
        systemExposureTask = Task { [weak self] in
            await previous?.value
            await self?.reconcileSystemReadingDonations(snapshot)
        }
    }
    private func donationState() -> SystemReadingDonationState {
        if let data = sourceDefaults.data(forKey: "Moonread.systemReadingDonations.v1"),
           let value = try? JSONDecoder().decode(SystemReadingDonationState.self, from: data), value.schemaVersion == 1 { return value }
        return .init(scope: "")
    }
    private func saveDonationState(_ value: SystemReadingDonationState) throws {
        sourceDefaults.set(try JSONEncoder().encode(value), forKey: "Moonread.systemReadingDonations.v1")
    }
    private func reconcileSystemReadingDonations(_ snapshot: SystemReadingSnapshot) async {
        guard systemCatalog?.scope == snapshot.storeScope else { return }
        var state = donationState()
        do {
            if state.scope != snapshot.storeScope {
                try await IntentDonationManager.shared.deleteDonations(matching: .intentType(OpenSystemBookIntent.self))
                state = .init(scope: snapshot.storeScope)
                try saveDonationState(state)
            }
            let allowed = Set(snapshot.books.filter(\.allowsAutomaticExposure).map(\.id))
            for id in state.bookIDs where !allowed.contains(id) {
                try await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifier(EntityIdentifier(for: SystemBookEntity.self, identifier: id)))
                state.bookIDs.removeAll { $0 == id }
                try saveDonationState(state)
            }
        } catch {
            // IDs remain recorded until a revoke succeeds; next foreground/publication retries.
            // Optional system suggestions never block reading or modify user facts.
            systemCatalog?.error = ReaderMessages.error(error)
        }
    }
    func systemReadingBegan(_ bookID: String) async {
        guard libraryDirectoryOverride == nil, testSession == nil, systemCatalog != nil, let sha = try? userKey(bookID), (try? parseSha256(value: sha)) != nil else { return }
        scheduleSystemReadingCatalog(immediate: true)
        await waitForSystemReadingCatalog()
        guard let catalog = systemCatalog, !catalog.accountPending,
              let snapshot = try? catalog.file.read(),
              let book = snapshot.books.first(where: { $0.id == "book:" + sha && $0.allowsAutomaticExposure }) else { return }
        let previous = systemExposureTask
        systemExposureTask = Task { [weak self] in
            await previous?.value
            await self?.donateSystemReading(book, scope: snapshot.storeScope)
        }
    }
    private func donateSystemReading(_ book: SystemReadingSnapshot.Book, scope: String) async {
        let policy = systemExposurePolicy()
        guard policy.systemSearchEnabled, systemCatalog?.scope == scope, systemCatalog?.accountPending == false,
              let snapshot = try? systemCatalog?.file.read(), snapshot.exposurePolicy == policy,
              snapshot.books.contains(where: { $0.id == book.id && $0.allowsAutomaticExposure }) else { return }
        var state = donationState()
        guard state.scope == scope else { return } // A failed old-scope revocation must finish first.
        do {
            // Record before awaiting the system, so an interrupted donation can still be revoked.
            if !state.bookIDs.contains(book.id) { state.bookIDs.append(book.id); try saveDonationState(state) }
            _ = try await IntentDonationManager.shared.donate(intent: OpenSystemBookIntent(target: .init(book: book)))
            if systemCatalog?.scope != scope || systemCatalog?.accountPending == true || systemExposurePolicy() != policy {
                try await IntentDonationManager.shared.deleteDonations(matching: .entityIdentifier(EntityIdentifier(for: SystemBookEntity.self, identifier: book.id)))
            }
        } catch { systemCatalog?.error = ReaderMessages.error(error) }
    }
}

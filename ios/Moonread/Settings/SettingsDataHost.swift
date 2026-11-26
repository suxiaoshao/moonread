import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import MoonreadLibrary
import MoonreadSettings
import SwiftUI

extension DataManagementModel {
    convenience init(service: AppDataService = .shared) {
        let backupImport = BackupImportTask(
            actions: .init(
                authorize: { ProtectedFileAccess.Source(selectedFile: $0) },
                stage: { try await service.stageReadingBackup($0) },
                preview: { try await service.previewReadingBackup($0) },
                restore: { try await service.importReadingBackup($0) }
            ), execution: service === AppDataService.shared ? DataExchangeSystemExecution().execution : nil
        )
        self.init(actions: .init(
            inventory: { try await service.readingDataInventory() },
            promote: { try await service.promoteUserData($0, retry: true) },
            continuePending: { try await service.continuePendingReadingData($0) },
            exportBackup: { try await service.exportReadingData() },
            share: { try await service.readingBackupShareCopy($0) },
            delete: { try await service.deleteReadingData($0, configuration: $1) }
        ), backupImport: backupImport,
        exportExecution: service === AppDataService.shared ? DataExchangeSystemExecution().execution : nil,
        deletionExecution: service === AppDataService.shared ? DataExchangeSystemExecution().execution : nil)
    }
}

struct SettingsDataHost: View {
    let library: LibraryModel

    var body: some View {
        DataManagementView(model: library.shell.dataManagement, processingFiles: library.processingFiles,
                           reconnectShelf: { library.chooseFiles(.folder($0)) }, chooseBackup: chooseFixtureBackup) {
            MetadataTasksSection(task: .shared, loadShelves: { try await AppDataService.shared.shelves() })
                .metadataCoverPresentation()
        }
        .navigationBarTitleDisplayMode(.large)
    }

    private func chooseFixtureBackup(_ exported: URL?) -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") { return exported }
        #endif
        return nil
    }
}

extension StorageSpaceModel {
    convenience init(service: AppDataService) {
        self.init(inventory: .init(
            overview: { try await service.storageOverview() },
            bodies: { try await service.bodyCacheInventory() },
            work: { try await service.storageWorkInventory() },
            legacy: { try await service.storageOldIndex() },
            database: { try await service.storageDatabaseInventory() },
            organize: { try await service.organizeStorageDatabase($0) }
        ))
    }
}

struct SettingsStorageHost: View {
    let library: LibraryModel
    let model: StorageSpaceModel
    @Environment(CloudStore.self) private var cloud

    var body: some View {
        StorageSpaceView(data: library.shell.dataManagement, model: model, actions: .init(
            activeReaders: { ids in
                library.shell.storageReaders.filter {
                    ids.contains($0.value.bookID) && library.shell.containsReaderDestination($0.key)
                }.mapValues(\.bookID)
            },
            clean: clean,
            databaseBusy: { cloud.status.syncing || MetadataExchangeModel.shared.saving || MetadataExchangeModel.shared.loading }
        ))
    }

    private func clean(_ request: StorageCleanupRequest) async -> (removed: UInt64, skipped: Bool) {
        let service = library.service
        var removed: UInt64 = 0
        var skipped = false
        var blocked = Set<String>()
        for (id, book) in request.readers {
            guard !Task.isCancelled else { break }
            guard let lease = request.bodyLease, let body = request.bodies.first(where: { $0.bookId == book }),
                  (try? await service.storageBodyCanClose(body, lease: lease)) == true else {
                blocked.insert(book)
                continue
            }
            guard let reader = library.shell.storageReaders[id], reader.bookID == book else { continue }
            if await !reader.close() { blocked.insert(book) }
        }
        for body in request.bodies {
            guard !Task.isCancelled else { break }
            do {
                if let lease = request.bodyLease, !blocked.contains(body.bookId),
                   try await service.evictStorageBody(body, lease: lease) {
                    removed += body.bytes
                } else { skipped = true }
            } catch { skipped = true }
        }
        if !Task.isCancelled, let lease = request.bodyLease, !request.covers.isEmpty {
            do { removed += try await service.clearStorageCoverCaches(request.covers, lease: lease) }
            catch { skipped = true }
        }
        if !Task.isCancelled, let work = request.work {
            do { removed += try await service.clearStorageWork(work) }
            catch { skipped = true }
        }
        if !Task.isCancelled, !request.legacy.isEmpty {
            do { removed += try await service.clearStorageOldIndex(request.legacy) }
            catch { skipped = true }
        }
        if request.bodies.count > 0 { NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil) }
        return (removed, skipped)
    }
}

import Foundation
import MoonreadData
import MoonreadDataTypes
import SwiftData

// Keep the published SwiftData model identities in the Moonread module.
extension LegacyUserSnapshot {
    init(scope: DataScope?, formal: ModelContainer? = nil, pending: ModelContainer? = nil,
         coverDirectory: URL? = nil, deviceState: DeviceState = .init()) {
        self.init(scope: scope, formalSource: formal.map(Self.project), pendingSource: pending.map(Self.project),
                  coverDirectory: coverDirectory, deviceState: deviceState)
    }

    /// The identity decision belongs to startup. This only opens the
    /// published files, with saves and CloudKit disabled. An unreadable file
    /// throws; only a confirmed missing file is represented by nil.
    static func open(directory: URL, scope: DataScope, deviceState: DeviceState,
                     progress: (@Sendable (LegacyImportProgress) -> Void)? = nil) throws -> Self {
        let schema = Schema([UserPosition.self, UserValue.self, AnnotationOperation.self,
                             ReadingFact.self, StatisticsClear.self, UserCover.self])
        func openStore(_ filename: String) throws -> ModelContainer? {
            let file = directory.appending(path: filename)
            do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return nil
            }
            progress?(.preparing)
            let configuration = ModelConfiguration("UserData", schema: schema, url: file,
                                                   allowsSave: false, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        return try .init(scope: scope, formal: openStore("user-data.store"),
                         pending: openStore("pending-users.store"),
                         coverDirectory: directory.appending(path: "Assets/Covers", directoryHint: .isDirectory),
                         deviceState: deviceState)
    }

    private static func sourceCount(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<UserCover>())
            + context.fetchCount(FetchDescriptor<UserValue>())
            + context.fetchCount(FetchDescriptor<UserPosition>())
            + context.fetchCount(FetchDescriptor<AnnotationOperation>())
            + context.fetchCount(FetchDescriptor<ReadingFact>())
            + context.fetchCount(FetchDescriptor<StatisticsClear>())
    }


    private static func project(_ container: ModelContainer) -> LegacyUserStore {
        .init(count: { try sourceCount(ModelContext(container)) }) {
            let context = ModelContext(container)
            func page<T: PersistentModel>(_ type: T.Type, _ offset: Int, _ limit: Int) throws -> [T] {
                var fetch = FetchDescriptor<T>()
                fetch.fetchOffset = offset
                fetch.fetchLimit = limit
                return try context.fetch(fetch)
            }
            return .init(
                covers: { offset, limit in try page(UserCover.self, offset, limit).map { .init(id: $0.id, bytes: $0.bytes) } },
                values: { offset, limit in try page(UserValue.self, offset, limit).map { .init(key: $0.key, device: $0.device, payload: $0.payload) } },
                positions: { offset, limit in try page(UserPosition.self, offset, limit).map { .init(contentKey: $0.contentKey, payload: $0.payload) } },
                annotations: { offset, limit in try page(AnnotationOperation.self, offset, limit).map {
                    .init(id: $0.id, contentKey: $0.contentKey, markID: $0.markID, payload: $0.payload)
                } },
                facts: { offset, limit in try page(ReadingFact.self, offset, limit).map {
                    .init(id: $0.id, contentKey: $0.contentKey, payload: $0.payload)
                } },
                clears: { offset, limit in try page(StatisticsClear.self, offset, limit).map(\.payload) }
            )
        }
    }
}

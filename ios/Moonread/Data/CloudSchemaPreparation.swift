#if DEBUG
import Foundation
import CoreData
import SwiftData
import SwiftUI

/// Explicit development tooling. Never uses the user's store or runs in Release.
enum CloudSchemaPreparation {
    static func model() throws -> NSManagedObjectModel {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: UserDataStore.modelTypes) else {
            throw CocoaError(.persistentStoreInvalidType)
        }
        return model
    }
    static func report() throws -> String {
        let model = try model()
        return model.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }.map { entity in
            let fields = entity.attributesByName.values.sorted { $0.name < $1.name }.map {
                "  \($0.name): \($0.attributeType.rawValue), optional=\($0.isOptional), external=\($0.allowsExternalBinaryDataStorage)"
            }.joined(separator: "\n")
            return (entity.name ?? "") + "\n" + fields
        }.joined(separator: "\n")
    }
    /// Writes DEVELOPMENT schema only when an explicit authorized launch argument requests it.
    /// Apple's initializer does not deploy production; Console deployment remains a user action.
    static func initializeDevelopmentSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-CloudSchema-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try autoreleasepool {
            let configuration = ModelConfiguration("SchemaPreparation", schema: UserDataStore.schema,
                url: root.appendingPathComponent("schema.store"), cloudKitDatabase: .private(CloudConfiguration.containerID))
            let description = NSPersistentStoreDescription(url: configuration.url)
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: CloudConfiguration.containerID)
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
            description.shouldAddStoreAsynchronously = false
            let container = NSPersistentCloudKitContainer(name: "SchemaPreparation", managedObjectModel: try model())
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            defer {
                for store in container.persistentStoreCoordinator.persistentStores { try? container.persistentStoreCoordinator.remove(store) }
            }
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema()
        }
    }
    static var requested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--cloud-schema-report") || args.contains("--initialize-cloudkit-development-schema")
    }
    static func runIfRequested() async -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--cloud-schema-report") || arguments.contains("--initialize-cloudkit-development-schema") else { return nil }
        return await Task.detached {
            do {
                let text = try report()
                print("Moonread development schema (local generated entities, not Console records):\n" + text)
                if arguments.contains("--initialize-cloudkit-development-schema") { try initializeDevelopmentSchema() }
                return text
            } catch {
                let error = error as NSError
                let text = "Schema preparation failed: \(error.domain) / \(error.code)"
                print(text)
                return text
            }
        }.value
    }
}
struct CloudSchemaPreparationScreen: View {
    @State private var report = "Preparing local model…"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Development schema preparation").font(.title2)
                Text(verbatim: "The normal application store is not opened here. Restart without the argument to enter Moonread.")
                Text(verbatim: report).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("cloudSchemaReport")
            }.padding()
        }.task { report = await CloudSchemaPreparation.runIfRequested() ?? "" }
    }
}
#endif

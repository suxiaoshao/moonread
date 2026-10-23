import Foundation
import SwiftUI

/// A description is syncable; a bookmark and the local shelf UUID are not.
struct ShelfReferenceValue: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var name: String
    var locationDescription: String
}

struct ShelfReference: Identifiable, Equatable, Sendable {
    let id: String
    let value: ShelfReferenceValue
    var locationLabel: String {
        value.locationDescription == "icloud-drive" ? String(localized: "iCloud Drive") : String(localized: "其他文件提供方", table: "ShelfRecovery")
    }
}

/// Device-only authorization and acknowledgement. Missing data is the v1 initial
/// state; an unknown version is never overwritten by an older installation.
struct ShelfReferenceBindings: Codable, Equatable {
    struct Scope: Codable, Equatable {
        var bindings: [String: String] = [:]
        var ignored: Set<String> = []
        var guided: Set<String> = []
        var recovery: Set<String>? = nil
        var published: [String: ShelfReferenceValue]? = nil
    }
    var schemaVersion = 1
    var scopes: [String: Scope] = [:]
    static let key = "Moonread.shelfReferenceBindings.v1"
    init(data: Data?) throws {
        if let data {
            self = try JSONDecoder().decode(Self.self, from: data)
            guard schemaVersion == 1 else { throw UserSyncCompatibilityError() }
        }
    }
    mutating func bind(_ reference: String, shelf: String, scope: String) {
        var value = scopes[scope] ?? Scope()
        value.bindings[reference] = shelf; value.ignored.remove(reference)
        scopes[scope] = value
    }
    mutating func forget(_ shelf: String, scope: String) {
        var value = scopes[scope] ?? Scope()
        for reference in value.bindings.filter({ $0.value == shelf }).keys {
            value.bindings.removeValue(forKey: reference); value.ignored.insert(reference)
        }
        scopes[scope] = value
    }
}

struct ShelfRecoverySnapshot: Sendable, Equatable {
    var scope: String = ""
    var references: [ShelfReference] = []
    var guidance: Set<String> = []
}

extension ReaderService {
    private var shelfReferenceScope: String {
        userDirectoryName + "/" + (sourceDefaults.string(forKey: "Moonread.userOwner") ?? "local")
    }
    private func shelfBindings() throws -> ShelfReferenceBindings {
        try ShelfReferenceBindings(data: sourceDefaults.data(forKey: ShelfReferenceBindings.key))
    }
    private func saveShelfBindings(_ bindings: ShelfReferenceBindings) throws {
        sourceDefaults.set(try JSONEncoder().encode(bindings), forKey: ShelfReferenceBindings.key)
    }
    /// Called after registration and on configuration/import refresh. Stable local
    /// IDs are saved before awaiting SwiftData, so reentrant retries reuse them.
    func shelfRecoverySnapshot() async throws -> ShelfRecoverySnapshot {
        let revision = userCloudConfigurationRevision, scope = shelfReferenceScope
        let store = try await userStore()
        guard revision == userCloudConfigurationRevision, scope == shelfReferenceScope else { throw CancellationError() }
        let shelves = try shelves()
        var changed = false
        for shelf in shelves where !shelf.builtin {
            var bindings = try shelfBindings()
            var ids = (bindings.scopes[scope]?.bindings ?? [:]).filter { $0.value == shelf.id }.keys.sorted()
            if ids.isEmpty {
                let id = UUID().uuidString
                bindings.bind(id, shelf: shelf.id, scope: scope); try saveShelfBindings(bindings)
                ids = [id]
            }
            let value = ShelfReferenceValue(name: shelf.name, locationDescription: shelf.location == "icloud" ? "icloud-drive" : "file-provider")
            for id in ids {
                // Publish local description changes, not a fresh LWW fact on every
                // remote import. Devices with different display names must not ping-pong.
                if bindings.scopes[scope]?.published?[id] == value { continue }
                let key = "shelf-reference/" + id
                do {
                    let old = try await store.value(key)
                    guard revision == userCloudConfigurationRevision, scope == shelfReferenceScope else { throw CancellationError() }
                    guard let current = try? libraryShelf(shelf.id), current.name == shelf.name, current.location == shelf.location,
                          try shelfBindings().scopes[scope]?.bindings[id] == shelf.id else { continue }
                    if old.flatMap({ try? JSONDecoder().decode(ShelfReferenceValue.self, from: Data($0.utf8)) }) != value {
                        try await store.put(key, value: UserSyncJSON.encode(value), device: userDevice); changed = true
                    }
                    guard revision == userCloudConfigurationRevision, scope == shelfReferenceScope else { throw CancellationError() }
                    var latest = try shelfBindings()
                    if latest.scopes[scope]?.bindings[id] == shelf.id {
                        var published = latest.scopes[scope]?.published ?? [:]
                        published[id] = value; latest.scopes[scope]?.published = published
                        try saveShelfBindings(latest)
                    }
                } catch is UserSyncCompatibilityError { continue }
            }
        }
        let references = try await store.shelfReferences()
        guard revision == userCloudConfigurationRevision, scope == shelfReferenceScope else { throw CancellationError() }
        let local = try shelfBindings().scopes[scope] ?? .init()
        let currentShelves = try self.shelves()
        let known = Set(currentShelves.map(\.id))
        let missing = references.filter { reference in
            guard !local.ignored.contains(reference.id) else { return false }
            guard let id = local.bindings[reference.id] else { return true }
            return !known.contains(id)
        }
        if changed { dataChanged() }
        let candidates = Set(currentShelves.filter { shelf in
            (shelf.builtin || (local.recovery ?? []).contains(shelf.id)) && !local.guided.contains(shelfGuidanceKey(shelf)) && indexScanIsCurrent(shelf.id)
        }.map(\.id))
        return ShelfRecoverySnapshot(scope: scope, references: missing.sorted {
            let order = $0.value.name.localizedStandardCompare($1.value.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, guidance: candidates)
    }
    func bindShelfReference(_ reference: String, shelf: String, scope: String) throws {
        guard scope == shelfReferenceScope else { throw CancellationError() }
        guard UUID(uuidString: reference) != nil, try !libraryShelf(shelf).builtin else { throw LibraryFileError.invalidDestination }
        var bindings = try shelfBindings()
        bindings.bind(reference, shelf: shelf, scope: shelfReferenceScope)
        try saveShelfBindings(bindings)
        try requestShelfRecoveryGuidance(shelf)
    }
    func forgetShelfReference(_ shelf: String) throws {
        var bindings = try shelfBindings(); bindings.forget(shelf, scope: shelfReferenceScope)
        try saveShelfBindings(bindings)
    }
    func acknowledgeShelfGuidance(_ shelf: String, scope: String) throws {
        guard scope == shelfReferenceScope else { throw CancellationError() }
        var bindings = try shelfBindings(), value = bindings.scopes[shelfReferenceScope] ?? .init()
        value.guided.insert(shelfGuidanceKey(try libraryShelf(shelf))); bindings.scopes[shelfReferenceScope] = value
        try saveShelfBindings(bindings)
    }
    private func shelfGuidanceKey(_ shelf: LibraryShelf) -> String { shelf.builtin ? "builtin-" + shelf.location : shelf.id }
    func requestShelfRecoveryGuidance(_ shelf: String) throws {
        var bindings = try shelfBindings(), value = bindings.scopes[shelfReferenceScope] ?? .init()
        value.guided.remove(shelf); value.recovery = (value.recovery ?? []).union([shelf])
        bindings.scopes[shelfReferenceScope] = value; try saveShelfBindings(bindings)
    }
    func registerRecoveredShelf(_ url: URL, reference: ShelfReference, scope: String) throws -> String {
        guard scope == shelfReferenceScope else { throw CancellationError() }
        let replacing = try shelfBindings().scopes[scope]?.bindings[reference.id]
        let id = try registerLibraryShelf(url, replacing: replacing)
        try bindShelfReference(reference.id, shelf: id, scope: scope)
        return id
    }
    /// The first opt-in keeps locally assigned logical IDs. Later account changes
    /// do not copy bindings into a different account's scope.
    func adoptLocalShelfBindings(account: String) throws {
        var bindings = try shelfBindings()
        let local = userDirectoryName + "/local", destination = userDirectoryName + "/" + account
        if bindings.scopes[destination] == nil, let value = bindings.scopes[local] {
            bindings.scopes[destination] = value; try saveShelfBindings(bindings)
        }
    }
}

/// A committed scan supplies an authorization scope, not another identity rule.
/// Only paths actually enumerated in a partial scan become automatic work.
struct LibraryIndexScan: Sendable {
    let shelfID: String
    let revision: UUID
    let files: Set<String>
}
extension Notification.Name { static let libraryIndexScanCommitted = Notification.Name("Moonread.libraryIndexScanCommitted") }

struct ShelfIndexSummary: Equatable {
    let pending: Int
    let cloudFiles: Int
    let cloudBytes: UInt64
    init(_ inventory: IdentityInventory) {
        pending = inventory.pending.count
        cloudFiles = inventory.pending.filter(\.needsDownload).count
        cloudBytes = inventory.cloudBytes
    }
}

extension LibraryModel {
    func refreshShelfRecovery() async {
        let token = UUID(); shelfRecoveryRequest = token
        do {
            let value = try await service.shelfRecoverySnapshot()
            guard shelfRecoveryRequest == token else { return }
            if shelfRecovery != value { shelfRecovery = value }
        } catch {
            if shelfRecoveryRequest == token { shelfRecovery = .init() }
        }
    }
    func indexScanCommitted(_ scan: LibraryIndexScan) async {
        guard await service.indexScanRevisions[scan.shelfID] == scan.revision else { return }
        await refreshShelfRecovery()
        await refreshIndexSummary(scan.shelfID)
        pendingIndexScans.insert(scan.shelfID)
        await coordinatePendingIndexes()
    }
    func refreshIndexSummary(_ shelf: String) async {
        let token = UUID(); indexSummaryRequests[shelf] = token
        guard let inventory = try? await service.identityInventory(shelf) else {
            if indexSummaryRequests[shelf] == token { shelfIndexes[shelf] = nil }
            return
        }
        guard indexSummaryRequests[shelf] == token else { return }
        let summary = ShelfIndexSummary(inventory)
        if shelfIndexes[shelf] != summary { shelfIndexes[shelf] = summary }
    }
    /// Passive discoveries never own a modal. File-work completion and explicit
    /// import prompts get their original ordering before automatic admission.
    func coordinatePendingIndexes(all: Bool = false) async {
        if all { pendingIndexScans.formUnion(shelves.map(\.id)) }
        guard initialized, canAcceptFileWork, indexPrompt == nil, deferredIndexPrompt == nil,
              sheet == nil, !filePickerPresented, fullIndex.automatic else { return }
        let ids = pendingIndexScans; pendingIndexScans.removeAll()
        for id in ids {
            guard fullIndex.automatic else { pendingIndexScans.insert(id); continue }
            guard let inventory = try? await service.identityInventory(id, scannedOnly: true), !inventory.local.isEmpty,
                  fullIndex.canContinue(inventory, includeCloud: false) else { continue }
            guard canAcceptFileWork, indexPrompt == nil, deferredIndexPrompt == nil, sheet == nil, !filePickerPresented else {
                pendingIndexScans.insert(id); continue
            }
            fullIndex.start(id, includeCloud: false, userInitiated: false, scannedOnly: true, files: inventory.local)
        }
    }
    func openShelfIndex(_ shelf: String) async {
        guard canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
        if shelfRecovery.guidance.contains(shelf) {
            do { try await service.acknowledgeShelfGuidance(shelf, scope: shelfRecovery.scope) }
            catch { return }
            await refreshShelfRecovery()
        }
        guard canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
        sheet = .fullIndex(shelf)
    }
    func deferShelfRecovery(_ shelf: String) async {
        do { try await service.acknowledgeShelfGuidance(shelf, scope: shelfRecovery.scope) }
        catch { return }
        await refreshShelfRecovery()
    }
    func reauthorizeShelf(_ reference: ShelfReference) {
        let scope = shelfRecovery.scope
        #if DEBUG
        Task {
            if let url = await service.shelfRecoveryFixtureURL(reference.id) {
                selectSource(url, restoring: reference, scope: scope)
            } else { chooseFiles(.reauthorize(reference, scope: scope)) }
        }
        #else
        chooseFiles(.reauthorize(reference, scope: scope))
        #endif
    }
}

/// Non-modal guidance; FullIndex remains the sole task/progress/download UI.
struct ShelfIndexGuidance: View {
    let model: LibraryModel
    let shelfID: String
    private var recovery: Bool { model.shelfRecovery.guidance.contains(shelfID) }
    var body: some View {
        if let summary = model.shelfIndexes[shelfID], summary.pending > 0 {
            VStack(alignment: .leading, spacing: 8) {
                if recovery {
                    Text("建立索引以恢复整个书架", tableName: "ShelfRecovery").font(.headline)
                    Text("索引完成后，已有阅读进度和标签会重新显示。", tableName: "ShelfRecovery").font(.caption).foregroundStyle(.secondary)
                }
                Text("有 \(summary.pending) 本未索引", tableName: "ShelfRecovery").font(.subheadline)
                if summary.cloudFiles > 0 {
                    Text("包含 \(summary.cloudFiles) 本未下载的 iCloud 文件", tableName: "ShelfRecovery").font(.caption).foregroundStyle(.secondary)
                }
                if summary.cloudBytes > 0 {
                    Text("已知下载量：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.cloudBytes), countStyle: .file))", tableName: "ShelfRecovery").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { Task { await model.openShelfIndex(shelfID) } } label: { Text("建立索引", tableName: "FullIndex") }
                        .accessibilityIdentifier("recoverWholeShelf-" + shelfID)
                    if recovery {
                        Button { Task { await model.deferShelfRecovery(shelfID) } } label: { Text("以后再说", tableName: "ShelfRecovery") }
                    }
                }
            }.buttonStyle(.borderless).padding(.vertical, 8)
                .disabled(!model.canAcceptFileWork)
        }
    }
}

struct ShelfReferenceHints: View {
    let model: LibraryModel
    var body: some View {
        if !model.shelfRecovery.references.isEmpty {
            Section {
                ForEach(model.shelfRecovery.references) { reference in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: reference.value.name).font(.headline)
                        Text(reference.locationLabel).font(.caption).foregroundStyle(.secondary)
                        Text("需要重新授权", tableName: "ShelfRecovery").font(.caption).foregroundStyle(.secondary)
                        Button { model.reauthorizeShelf(reference) } label: { Text("重新授权", tableName: "ShelfRecovery") }
                            .accessibilityIdentifier("reauthorizeShelf-" + reference.id)
                            .disabled(!model.canAcceptFileWork)
                    }.padding(.vertical, 6)
                }
            } header: { Text("你之前添加过这些书架", tableName: "ShelfRecovery") }
        }
    }
}

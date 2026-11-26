import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
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
    struct Scope: Codable, Equatable, Sendable {
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
    static func read(_ db: Database) throws -> Scope {
        var scope = Scope()
        for row in try Row.fetchAll(db, sql: "SELECT key,kind,value FROM usr.local_shelf_recovery") {
            let key: String = row["key"]
            let kind: String = row["kind"]
            switch kind {
            case "binding":
                scope.bindings[key] = try JSONDecoder().decode(String.self, from: row["value"])
            case "ignored": scope.ignored.insert(key)
            case "guided": scope.guided.insert(key)
            case "recovery": scope.recovery = (scope.recovery ?? []).union([key])
            case "published":
                if scope.published == nil { scope.published = [:] }
                scope.published?[key] = try JSONDecoder().decode(ShelfReferenceValue.self, from: row["value"])
            default: throw UserSyncCompatibilityError()
            }
        }
        return scope
    }

    static func write(_ db: Database, scope: Scope) throws {
        try db.execute(sql: "DELETE FROM usr.local_shelf_recovery")
        func insert(_ key: String, _ kind: String, value: Data? = nil) throws {
            try db.execute(sql: "INSERT INTO usr.local_shelf_recovery VALUES(?,?,?)", arguments: [key,kind,value])
        }
        for (key, value) in scope.bindings { try insert(key,"binding",value: JSONEncoder().encode(value)) }
        for key in scope.ignored { try insert(key,"ignored") }
        for key in scope.guided { try insert(key,"guided") }
        for key in scope.recovery ?? [] { try insert(key,"recovery") }
        for (key, value) in scope.published ?? [:] { try insert(key,"published",value: JSONEncoder().encode(value)) }
    }
}

struct ShelfRecoverySnapshot: Sendable, Equatable {
    var scope: String = ""
    var references: [ShelfReference] = []
    var guidance: Set<String> = []
}

extension AppDataService {
    private var shelfReferenceScope: String {
        get throws { try indexStore().lease.scope.key }
    }
    private func shelfBindings() throws -> ShelfReferenceBindings.Scope {
        let index = try relationalUserIndex()
        return try index.session.readUsers(index.lease) { try ShelfReferenceBindings.read($0) }
    }
    private func saveShelfBindings(_ bindings: ShelfReferenceBindings.Scope) throws {
        let index = try relationalUserIndex()
        try index.session.writeUsers(index.lease) { try ShelfReferenceBindings.write($0, scope: bindings) }
    }
    /// Called after registration and on configuration/import refresh. Stable local
    /// IDs are saved locally before publishing the description.
    func shelfRecoverySnapshot() async throws -> ShelfRecoverySnapshot {
        let revision = userCloudConfigurationRevision, scope = try shelfReferenceScope
        try await acquireCancellableUserDataOperation(); defer { releaseUserDataOperation() }
        guard revision == userCloudConfigurationRevision, scope == (try shelfReferenceScope) else { throw CancellationError() }
        let index = try relationalUserIndex()
        let shelves = try shelves()
        try bindMatchingShelfReferences(shelves, index: index)
        var changed = false
        for shelf in shelves where !shelf.builtin {
            var bindings = try shelfBindings()
            var ids = bindings.bindings.filter { $0.value == shelf.id }.keys.sorted()
            if ids.isEmpty {
                let id = UUID().uuidString
                bindings.bindings[id] = shelf.id; bindings.ignored.remove(id); try saveShelfBindings(bindings)
                ids = [id]
            }
            let value = shelfReferenceValue(for: shelf)
            for id in ids {
                // Publish local description changes, not a fresh LWW fact on every
                // remote import. Devices with different display names must not ping-pong.
                if bindings.published?[id] == value { continue }
                let key = "shelf-reference/" + id
                do {
                    guard let current = try? libraryShelf(shelf.id), current.name == shelf.name, current.location == shelf.location,
                          try shelfBindings().bindings[id] == shelf.id else { continue }
                    if try index.session.writeUsers(index.lease, { db in
                        guard try UserValueRows.shelfReferences(db, id: id).first?.value != value else { return false }
                        try UserValueRows.put(db, key: .init(key), value: UserSyncJSON.encode(value), device: userDevice, now: userValueClock,
                                              scope: index.lease.scope)
                        return true
                    }) {
                        changed = true
                    }
                    guard revision == userCloudConfigurationRevision, scope == (try shelfReferenceScope) else { throw CancellationError() }
                    var latest = try shelfBindings()
                    if latest.bindings[id] == shelf.id {
                        var published = latest.published ?? [:]
                        published[id] = value; latest.published = published
                        try saveShelfBindings(latest)
                    }
                } catch is UserSyncCompatibilityError { continue }
            }
        }
        let references = try index.session.readUsers(index.lease) { try UserValueRows.shelfReferences($0) }
        guard revision == userCloudConfigurationRevision, scope == (try shelfReferenceScope) else { throw CancellationError() }
        let local = try shelfBindings()
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
    private func shelfReferenceValue(for shelf: LibraryShelf) -> ShelfReferenceValue {
        ShelfReferenceValue(name: shelf.name, locationDescription: shelf.location == "icloud" ? "icloud-drive" : "file-provider")
    }

    private func bindMatchingShelfReferences(_ shelves: [LibraryShelf], index: ReaderIndex) throws {
        let references = try index.session.readUsers(index.lease) { try UserValueRows.shelfReferences($0) }
        var local = try shelfBindings()
        let pending = references.filter { local.bindings[$0.id] == nil && !local.ignored.contains($0.id) }
        guard !pending.isEmpty else { return }

        let attached = try shelves.filter { shelf in
            guard !shelf.builtin, shelf.error == nil else { return false }
            if case .external(.usable) = try shelfSource(shelf) { return true }
            return false
        }
        var bound = false
        for reference in pending {
            if let shelf = attached.first(where: { shelfReferenceValue(for: $0) == reference.value }) {
                local.bindings[reference.id] = shelf.id
                bound = true
            }
        }
        if bound { try saveShelfBindings(local) }
    }

    func bindShelfReference(_ reference: String, shelf: String, scope: String) throws {
        guard scope == (try shelfReferenceScope) else { throw CancellationError() }
        guard UUID(uuidString: reference) != nil, try !libraryShelf(shelf).builtin else { throw LibraryFileError.invalidDestination }
        var bindings = try shelfBindings()
        bindings.bindings[reference] = shelf; bindings.ignored.remove(reference)
        try saveShelfBindings(bindings)
        try requestShelfRecoveryGuidance(shelf)
    }
    func forgetShelfReference(_ shelf: String) throws {
        var bindings = try shelfBindings()
        for reference in bindings.bindings.filter({ $0.value == shelf }).keys {
            bindings.bindings.removeValue(forKey: reference); bindings.ignored.insert(reference)
        }
        try saveShelfBindings(bindings)
    }
    func acknowledgeShelfGuidance(_ shelf: String, scope: String) throws {
        guard scope == (try shelfReferenceScope) else { throw CancellationError() }
        var bindings = try shelfBindings()
        bindings.guided.insert(shelfGuidanceKey(try libraryShelf(shelf)))
        try saveShelfBindings(bindings)
    }
    private func shelfGuidanceKey(_ shelf: LibraryShelf) -> String { shelf.builtin ? "builtin-" + shelf.location : shelf.id }
    func requestShelfRecoveryGuidance(_ shelf: String) throws {
        var bindings = try shelfBindings()
        bindings.guided.remove(shelf); bindings.recovery = (bindings.recovery ?? []).union([shelf])
        try saveShelfBindings(bindings)
    }
    func registerRecoveredShelf(_ url: URL, reference: ShelfReference, scope: String) throws -> String {
        guard scope == (try shelfReferenceScope) else { throw CancellationError() }
        let replacing = try shelfBindings().bindings[reference.id]
        let id = try registerLibraryShelf(url, replacing: replacing)
        try bindShelfReference(reference.id, shelf: id, scope: scope)
        return id
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
    @Environment(\.theme) private var theme
    let model: LibraryModel
    let shelfID: String
    private var recovery: Bool { model.shelfRecovery.guidance.contains(shelfID) }
    var body: some View {
        if let summary = model.shelfIndexes[shelfID], summary.pending > 0 {
            HStack(alignment: .center, spacing: 12) {
                if recovery { Image(systemName: "arrow.clockwise.icloud").foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) {
                    if recovery { Text("建立索引以恢复进度与标签", tableName: "ShelfRecovery").font(.subheadline).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                    else { Text("\(summary.pending) 本还没建立索引", tableName: "ShelfRecovery").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                Spacer(minLength: 4)
                Button { Task { await model.openShelfIndex(shelfID) } } label: { Text("建立索引", tableName: "FullIndex") }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("recoverWholeShelf-" + shelfID)
                if recovery {
                    Button { Task { await model.deferShelfRecovery(shelfID) } } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless).accessibilityLabel(Text("以后再说", tableName: "ShelfRecovery"))
                }
            }.padding(.vertical, 6)
                .disabled(!model.canAcceptFileWork)
        }
    }
}

/// The home only summarizes; per-source authorization stays in management.
struct ShelfRecoverySummary: View {
    let model: LibraryModel
    @Environment(\.theme) private var theme
    var body: some View {
        if !model.shelfRecovery.references.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.accent))
                VStack(alignment: .leading, spacing: 4) {
                    Text("有 \(model.shelfRecovery.references.count) 个书架需要重新连接")
                        .accessibilityIdentifier("shelfRecoverySummary")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: theme.ink))
                    Text("阅读数据仍然保留").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                NavigationLink(value: LibraryRoute.manage) {
                    HStack(spacing: 4) { Text("处理"); Image(systemName: "chevron.right") }.font(.subheadline)
                }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
                    .accessibilityIdentifier("manageShelfRecovery")
            }.padding(14).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
        }
    }
}

struct ShelfReferenceRow: View {
    @Environment(\.theme) private var theme
    let model: LibraryModel
    let reference: ShelfReference
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: reference.value.name).font(.headline)
            Text(reference.locationLabel).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
            Button { model.reauthorizeShelf(reference) } label: { Text("重新连接", tableName: "Localizable") }
                .buttonStyle(ThemedSecondaryButtonStyle())
                .accessibilityIdentifier("reauthorizeShelf-" + reference.id)
                .disabled(!model.canAcceptFileWork)
        }.padding(.vertical, 6)
    }
}

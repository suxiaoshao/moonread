import Foundation
import Observation

struct AIOrganizationInput: AIReadingInput {
    struct Folder: Codable, Sendable { var temporaryRef: String; var parentRef: String; var name: String }
    struct Placement: Codable, Sendable { var fileRef: String; var parentRef: String; var name: String? }
    var scopeRef: String
    var folders: [Folder]
    var placements: [Placement]
    func validate() throws {
        let temporary = Set(folders.map(\.temporaryRef))
        let real = Set(placements.map(\.fileRef)).union([scopeRef])
        let reserved = Set(["b", "s", "d", "f", "c", "mark", "session", "source", "web", "v", "asset", "cursor", "proposal", "preview"])
        guard temporary.count == folders.count,
              Set(placements.map(\.fileRef)).count == placements.count,
              temporary.isDisjoint(with: real),
              temporary.allSatisfy({ ref in
                  !ref.isEmpty && (!ref.contains(":") || !reserved.contains(String(ref.prefix { $0 != ":" })))
              }) else { throw AIToolError("invalid_argument", field: "temporaryRef") }

    }
}
struct AIOrganizationProposal: Codable, Sendable {
    var proposalRef: String
    var previewRef: String
    var input: AIOrganizationInput
}
struct AIFileSnapshot: Codable, Equatable, Sendable {
    var shelfID: String
    var path: String
    var root: String
    var directory: Bool
    var hash: String?
    var location: LibraryLocation { .init(shelfID: shelfID, path: path) }
}
struct AIFileMoveCheck: Sendable {
    var source: AIFileSnapshot
    var sourceParent: AIFileSnapshot
    var destination: AIFileSnapshot
}
enum AIFileFailureReason: String, Sendable { case changed, occupied, permission, other }
enum AIFileExecutionStage: String, Codable, Sendable { case notMoved, completed, movedButIndexFailed, copiedSourceRemains, uncertain }
struct AIFileExecutionResult: Sendable, Identifiable {
    var id: String
    var stage: AIFileExecutionStage
    var message: String?
    var reason: AIFileFailureReason?
    var canExecuteRemaining: Bool { stage == .notMoved }
}
struct AIFileExecutionError: Error { var stage: AIFileExecutionStage; var underlying: Error }
enum AIOrganizationConflict: String, Codable, Sendable { case invalidName, outsideScope, duplicate, cycle, occupied, changed, dependency, unavailable }
@MainActor @Observable final class AIOrganizationNode: Identifiable {
    enum Kind: String, Sendable { case newFolder, move, rename }
    nonisolated let id: String
    let kind: Kind
    let parentRef: String
    let fileRef: String?
    let originalLocation: LibraryLocation?
    let originalName: String?
    var name: String
    var included = true
    var conflict: AIOrganizationConflict?
    var changedSincePreview = false
    var result: AIFileExecutionResult?
    init(id: String, kind: Kind, parentRef: String, fileRef: String? = nil, name: String, original: LibraryEntry? = nil) {
        self.id = id; self.kind = kind; self.parentRef = parentRef; self.fileRef = fileRef; self.name = name
        originalLocation = original?.location; originalName = original?.name
    }
}
struct AIOrganizationTreeItem: Codable, Identifiable, Sendable {
    enum Change: String, Codable, Sendable { case unchanged, newFolder, move, rename }
    var id: String
    var parentRef: String
    var name: String
    var directory: Bool
    var change: Change
    var originalPath: String?
}
@MainActor @Observable final class AIOrganizationPlan {
    let proposal: AIOrganizationProposal
    let canExecute: Bool
    var previewRef: String { proposal.previewRef }
    var nodes: [AIOrganizationNode] = []
    private var originalTree: [AIOrganizationTreeItem] = []
    var targetTree: [AIOrganizationTreeItem] {
        var items = originalTree
        for node in nodes where node.included && node.conflict != .cycle && node.conflict != .outsideScope && node.conflict != .dependency {
            if node.kind == .newFolder { items.append(.init(id: node.id, parentRef: node.parentRef, name: node.name, directory: true, change: .newFolder)) }
            else if let index = items.firstIndex(where: { $0.id == node.id }) { items[index].parentRef = node.parentRef; items[index].name = node.name; items[index].change = node.kind == .move ? .move : .rename }
        }
        return items
    }
    var executing = false
    var results: [AIFileExecutionResult] { nodes.compactMap(\.result) }
    var pendingCount: Int { nodes.filter { $0.result?.stage != .completed }.count }
    var includedCount: Int { nodes.filter { $0.included }.count }
    @ObservationIgnored private let reader: ReaderService
    @ObservationIgnored private let references: AIReadingReferences
    @ObservationIgnored private let scope: LibraryLocation
    @ObservationIgnored private var snapshots: [String: AIFileSnapshot] = [:]
    @ObservationIgnored private var entries: [String: LibraryEntry] = [:]
    @ObservationIgnored private var occupied: [String: Set<String>] = [:]
    @ObservationIgnored private let moveItem: @MainActor (LibraryEntry, LibraryLocation, String, AIFileMoveCheck) async -> AIFileExecutionResult
    init(proposal: AIOrganizationProposal, scope: LibraryLocation, reader: ReaderService = .shared, historical: Bool = false,
         moveItem: (@MainActor (LibraryEntry, LibraryLocation, String, AIFileMoveCheck) async -> AIFileExecutionResult)? = nil) {
        canExecute = !historical
        self.proposal = proposal; self.scope = scope; self.reader = reader
        references = AIReadingReferences(reader: reader)
        self.moveItem = moveItem ?? { await reader.aiMoveLibraryItem($0, to: $1, name: $2, check: $3) }
        if historical {
            for folder in proposal.input.folders { nodes.append(.init(id: folder.temporaryRef, kind: .newFolder, parentRef: folder.parentRef, name: folder.name)) }
            for placement in proposal.input.placements { nodes.append(.init(id: placement.fileRef, kind: .move, parentRef: placement.parentRef, fileRef: placement.fileRef, name: placement.name ?? "File")) }
            for node in nodes { node.included = false; node.conflict = .unavailable }
        }
    }
    private func contains(_ location: LibraryLocation) -> Bool {
        location.shelfID == scope.shelfID && (scope.path.isEmpty || location.path == scope.path || location.path.hasPrefix(scope.path + "/"))
    }
    func prepare() async throws {
        try proposal.input.validate()
        var locations = [scope]
        while let location = locations.popLast() {
            try Task.checkCancellation()
            let parentRef = AIReadingTools.scopeRef(shelfID: location.shelfID, path: location.path)
            for entry in try await reader.libraryEntries(location) {
                let ref = entry.directory ? AIReadingTools.scopeRef(shelfID: entry.shelfId, path: entry.relativePath) : AIReadingTools.ref("f", entry.id)
                originalTree.append(.init(id: ref, parentRef: parentRef, name: entry.name, directory: entry.directory, change: .unchanged, originalPath: entry.relativePath))
                if entry.directory { locations.append(entry.location) }
            }
        }
        let state = try await reader.aiDirectoryState(scope)
        snapshots[proposal.input.scopeRef] = state.snapshot
        occupied[proposal.input.scopeRef] = state.names
        let temporary = Set(proposal.input.folders.map(\.temporaryRef))
        for folder in proposal.input.folders {
            if !temporary.contains(folder.parentRef) { try await captureParent(folder.parentRef) }
            nodes.append(.init(id: folder.temporaryRef, kind: .newFolder, parentRef: folder.parentRef, name: folder.name))
        }
        for placement in proposal.input.placements {
            let entry = try await references.file(placement.fileRef)
            guard contains(entry.location), !entry.directory else { throw AIToolError("permission_denied") }
            entries[placement.fileRef] = entry
            snapshots[placement.fileRef] = try await reader.aiFileSnapshot(entry.location)
            let parentRef = AIReadingTools.scopeRef(shelfID: entry.shelfId, path: entry.parent.path)
            try await captureParent(parentRef)
            if !temporary.contains(placement.parentRef) { try await captureParent(placement.parentRef) }
            nodes.append(.init(id: placement.fileRef, kind: placement.parentRef == parentRef ? .rename : .move,
                parentRef: placement.parentRef, fileRef: placement.fileRef, name: placement.name ?? entry.name, original: entry))
        }
        recomputeConflicts()
    }
    func displayLocation(_ ref: String) -> LibraryLocation? {
        if let snapshot = snapshots[ref] { return snapshot.location }
        guard let node = nodes.first(where: { $0.id == ref && $0.kind == .newFolder }), node.conflict != .cycle,
              let parent = displayLocation(node.parentRef) else { return nil }
        return .init(shelfID: parent.shelfID, path: parent.path.isEmpty ? node.name : parent.path + "/" + node.name)
    }
    var scopeLocation: LibraryLocation { scope }
    private func captureParent(_ ref: String) async throws {
        if snapshots[ref] != nil { return }
        let location = try await references.location(ref)
        guard contains(location) else { throw AIToolError("permission_denied") }
        let state = try await reader.aiDirectoryState(location)
        snapshots[ref] = state.snapshot
        occupied[ref] = state.names
    }
    func recomputeConflicts() {
        for node in nodes where node.result == nil || node.result?.canExecuteRemaining == true {
            node.conflict = nil
            if node.changedSincePreview { node.conflict = .changed; continue }
            if node.name.isEmpty || node.name == "." || node.name == ".." || node.name.contains("/") || node.name.contains("\\") || node.name.hasPrefix(".") { node.conflict = .invalidName }
            var seen: Set<String> = [node.id], parent = node.parentRef
            while let ancestor = nodes.first(where: { $0.id == parent && $0.kind == .newFolder }) {
                guard seen.insert(parent).inserted else { node.conflict = .cycle; break }
                if !ancestor.included || (ancestor.result != nil && ancestor.result?.canExecuteRemaining != true && snapshots[ancestor.id] == nil) {
                    node.conflict = .dependency
                }
                parent = ancestor.parentRef
            }
            if occupied[node.parentRef]?.contains(node.name) == true && !(node.originalLocation?.path == ((snapshots[node.parentRef]?.path.isEmpty == true ? "" : (snapshots[node.parentRef]?.path ?? "") + "/") + node.name)) { node.conflict = .occupied }
            if snapshots[parent] == nil { node.conflict = .outsideScope }
            if nodes.contains(where: { $0.id != node.id && $0.included && $0.parentRef == node.parentRef && $0.name == node.name }) { node.conflict = .duplicate }
        }
    }
    var eligibleNodeIDs: Set<String> {
        Set(nodes.filter { $0.included && $0.conflict == nil && ($0.result == nil || $0.result?.canExecuteRemaining == true) }.map(\.id))
    }
    @discardableResult func execute() async -> [AIFileExecutionResult] { await executeRemaining(confirmedIDs: eligibleNodeIDs) }
    @discardableResult func executeRemaining(confirmedIDs: Set<String>? = nil) async -> [AIFileExecutionResult] {
        guard canExecute, !executing else { return results }; executing = true; defer { executing = false }
        // Freeze admission before any operation can free a previously occupied name.
        let confirmed = confirmedIDs ?? eligibleNodeIDs
        recomputeConflicts()
        var pending = nodes.filter { confirmed.contains($0.id) && $0.included && ($0.result == nil || $0.result?.canExecuteRemaining == true) }
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: { snapshots[$0.parentRef] != nil || $0.conflict != nil }) else {
                for node in pending { node.conflict = .dependency; node.result = .init(id: node.id, stage: .notMoved, message: "dependency") }; break
            }
            let node = pending.remove(at: index)
            guard node.conflict == nil, let destination = snapshots[node.parentRef] else {
                node.result = .init(id: node.id, stage: .notMoved, message: node.conflict?.rawValue ?? "dependency",
                    reason: node.conflict == .changed ? .changed : node.conflict == .occupied ? .occupied : nil); continue
            }
            do {
                let result: AIFileExecutionResult
                if node.kind == .newFolder {
                    result = try await reader.aiCreateLibraryFolder(at: destination, name: node.name, id: node.id)
                    node.result = result
                } else {
                    guard let fileRef = node.fileRef, let source = snapshots[fileRef], let entry = entries[fileRef],
                          let sourceParent = snapshots[AIReadingTools.scopeRef(shelfID: entry.shelfId, path: entry.parent.path)] else { throw AIToolError("stale_reference") }
                    result = await moveItem(entry, destination.location, node.name,
                        .init(source: source, sourceParent: sourceParent, destination: destination))
                }
                node.result = result
                updateOccupancy(node, result: result)
                if node.kind == .newFolder && [.completed, .movedButIndexFailed].contains(result.stage) {
                    // A missing fresh child baseline blocks its dependencies, not the successful creation.
                    if let state = try? await reader.aiDirectoryState(.init(shelfID: destination.shelfID, path: destination.path.isEmpty ? node.name : destination.path + "/" + node.name)), state.names == occupied[node.id] {
                        snapshots[node.id] = state.snapshot
                    }
                }
                if [.completed, .movedButIndexFailed, .copiedSourceRemains].contains(result.stage) {
                    // Advance only identities this execution itself changed, preserving other preview baselines.
                    let touched = Set([destination.location, entries[node.id]?.parent].compactMap { $0 })
                    for (ref, old) in snapshots where touched.contains(old.location) {
                        do {
                            let state = try await reader.aiDirectoryState(old.location)
                            guard state.snapshot == old, state.names == occupied[ref] else { throw AIToolError("stale_reference") }
                            snapshots[ref] = state.snapshot
                        } catch {
                            // Retain the old baseline and actual business stage. Only dependent
                            // remaining operations lose eligibility for this now-stale directory.
                            for remaining in nodes where remaining.result == nil || remaining.result?.canExecuteRemaining == true {
                                if remaining.parentRef == ref || entries[remaining.id]?.parent == old.location {
                                    remaining.changedSincePreview = true
                                }
                            }
                        }
                    }
                }
                if result.stage == .notMoved { node.changedSincePreview = result.reason == .changed; node.conflict = result.reason == .occupied ? .occupied : result.reason == .changed ? .changed : .unavailable }
            } catch {
                if node.result == nil || node.result?.canExecuteRemaining == true {
                    node.result = .init(id: node.id, stage: .notMoved, message: AIRequestError.message(error))
                    node.changedSincePreview = false
                }
            }
            recomputeConflicts()
            if node.result?.stage != .completed && node.kind == .newFolder {
                for dependent in pending where dependent.parentRef == node.id { dependent.conflict = .dependency }
            }
        }
        recomputeConflicts()
        return results
    }
    private func updateOccupancy(_ node: AIOrganizationNode, result: AIFileExecutionResult) {
        guard result.stage != .notMoved else { return }
        // Uncertain outcomes conservatively occupy the destination and never grant vacancy.
        occupied[node.parentRef, default: []].insert(node.name)
        if node.kind == .newFolder {
            if [.completed, .movedButIndexFailed].contains(result.stage) { occupied[node.id] = [] }
        } else if [.completed, .movedButIndexFailed].contains(result.stage), let entry = entries[node.id] {
            let parent = AIReadingTools.scopeRef(shelfID: entry.shelfId, path: entry.parent.path)
            if parent != node.parentRef || entry.name != node.name { occupied[parent]?.remove(entry.name) }
        }
    }
}

import MoonreadData
import SwiftUI

/// One in-memory transaction. Nested pages edit this draft, never the live search.
@MainActor @Observable public final class BookSearchDraft: Identifiable {
    public nonisolated let id = UUID()
    let original: BookSearchConfiguration
    public var value: BookSearchConfiguration
    public var pendingRuleChanged = false

    private struct PendingGroup {
        let parent: UUID
        var node: BookSearchNode
    }
    private var pendingGroups: [UUID: PendingGroup] = [:]
    public init(_ value: BookSearchConfiguration) { original = value; self.value = value }
    public var changed: Bool { value != original || pendingRuleChanged }
    public func node(_ id: UUID) -> BookSearchNode? {
        pendingGroups[id]?.node ?? find(value.root, id)
    }

    public func beginGroup(parent: UUID) -> UUID {
        let node = BookSearchNode()
        pendingGroups[node.id] = PendingGroup(parent: parent, node: node)
        return node.id
    }

    public func keepPendingGroups(_ ids: Set<UUID>) {
        pendingGroups = pendingGroups.filter { ids.contains($0.key) }
    }
    private func find(_ node: BookSearchNode, _ id: UUID) -> BookSearchNode? {
        if node.id == id { return node }
        for child in node.children { if let found = find(child, id) { return found } }
        return nil
    }
    public func edit(_ id: UUID, _ mutation: (inout BookSearchNode) -> Void) {
        if var pending = pendingGroups[id] {
            mutation(&pending.node)
            pendingGroups[id] = pending
        } else {
            edit(&value.root, id: id, mutation)
        }
    }
    public func exclusion(of node: BookSearchNode) -> Binding<Bool> {
        Binding(get: { self.node(node.id)?.excluded ?? node.excluded },
                set: { excluded in self.edit(node.id) { $0.excluded = excluded } })
    }
    private func edit(_ node: inout BookSearchNode, id: UUID, _ mutation: (inout BookSearchNode) -> Void) {
        if node.id == id { mutation(&node); return }
        for index in node.children.indices { edit(&node.children[index], id: id, mutation) }
    }
    public func save(_ node: BookSearchNode, parent: UUID) {
        edit(parent) { group in
            if let i = group.children.firstIndex(where: { $0.id == node.id }) { group.children[i] = node }
            else { group.children.append(node) }
        }
        // A first valid condition also completes any pending ancestor groups.
        if let pending = pendingGroups[parent], pending.node.validation() == nil {
            save(pending.node, parent: pending.parent)
            pendingGroups.removeValue(forKey: parent)
        }
    }
}

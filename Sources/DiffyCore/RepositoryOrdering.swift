import Foundation

/// The user's display order of repositories within a group.
///
/// The order is the order of `DiffyStore.repositories` itself. A group shows each top-level row
/// followed by its auto-discovered children, so rows only ever reorder among their **siblings**:
/// the top-level rows of one group, or the children of one parent. A parent carries its children
/// wherever it goes, and a child can never leave its parent.
public enum RepositoryOrdering {
    /// Put one set of siblings in `orderedIDs` order, reusing the array slots they already
    /// occupy so every other row (other groups, other families, hidden siblings) stays put.
    /// Returns nil when the IDs aren't siblings of one another or don't all exist.
    public static func reorder(_ repositories: [RepositoryConfig], siblings orderedIDs: [UUID]) -> [RepositoryConfig]? {
        guard orderedIDs.count > 1, Set(orderedIDs).count == orderedIDs.count else { return nil }
        let indexByID = Dictionary(
            repositories.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let slots = orderedIDs.compactMap { indexByID[$0] }
        guard slots.count == orderedIDs.count else { return nil }

        let first = repositories[slots[0]]
        guard slots.allSatisfy({
            repositories[$0].groupID == first.groupID
                && repositories[$0].parentRepositoryID == first.parentRepositoryID
        }) else { return nil }

        var result = repositories
        for (slot, index) in zip(slots.sorted(), slots) {
            result[slot] = repositories[index]
        }
        return result
    }

    /// Siblings of `id` in display order, after dropping it before `destination`, a flat index
    /// into `rows` as `List.onMove` reports it. A drop that would separate a child from its
    /// parent, or land a parent among another family's children, snaps to the nearest allowed
    /// place. Returns nil when nothing changes.
    public static func siblingOrder(moving id: UUID, toFlatIndex destination: Int, in rows: [RepositoryConfig]) -> [UUID]? {
        guard let moved = rows.first(where: { $0.id == id }) else { return nil }
        let siblings = rows.enumerated().filter { $0.element.parentRepositoryID == moved.parentRepositoryID }
        let others = siblings.filter { $0.element.id != id }
        var ids = others.map(\.element.id)
        ids.insert(id, at: others.filter { $0.offset < destination }.count)
        return ids == siblings.map(\.element.id) ? nil : ids
    }

    /// Siblings of `id` in display order after moving it `offset` places (negative is up),
    /// stopping at the first or last place. Returns nil when nothing changes.
    public static func siblingOrder(moving id: UUID, by offset: Int, in rows: [RepositoryConfig]) -> [UUID]? {
        guard let moved = rows.first(where: { $0.id == id }) else { return nil }
        var ids = rows.filter { $0.parentRepositoryID == moved.parentRepositoryID }.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return nil }
        let to = min(max(from + offset, 0), ids.count - 1)
        guard to != from else { return nil }
        ids.remove(at: from)
        ids.insert(id, at: to)
        return ids
    }
}

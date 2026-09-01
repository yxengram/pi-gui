import Foundation

/// The entry tree of a session, and the branch currently being viewed.
///
/// A session file holds every branch ever explored. What the user sees as "the
/// conversation" is one root-to-leaf path through it, so rendering a transcript is
/// really: pick a leaf, walk to the root, reverse.
public struct SessionTree: Sendable {
    public struct Node: Sendable, Identifiable {
        public let entry: SessionEntry
        public let childIDs: [String]
        public var id: String { entry.id }
    }

    public let nodesByID: [String: Node]
    public let rootIDs: [String]
    /// File order, used to break ties when choosing a default leaf.
    private let entryOrder: [String]

    public init(entries: [SessionEntry]) {
        var nodes: [String: SessionEntry] = [:]
        var children: [String: [String]] = [:]
        var roots: [String] = []
        var order: [String] = []

        for entry in entries {
            // A duplicate id would silently drop an entry; last write wins, matching
            // how an append-only log is replayed.
            nodes[entry.id] = entry
            order.append(entry.id)
        }

        for entry in entries {
            if let parentID = entry.parentID, nodes[parentID] != nil {
                children[parentID, default: []].append(entry.id)
            } else {
                // A missing parent means a truncated or partially-written file. Treating
                // the orphan as a root keeps its subtree reachable instead of hiding it.
                roots.append(entry.id)
            }
        }

        nodesByID = nodes.mapValues { entry in
            Node(entry: entry, childIDs: children[entry.id] ?? [])
        }
        rootIDs = roots
        entryOrder = order
    }

    public var isEmpty: Bool { nodesByID.isEmpty }

    /// The path from the root down to `leafID`, in conversation order.
    public func branch(endingAt leafID: String) -> [SessionEntry] {
        var reversed: [SessionEntry] = []
        var cursor: String? = leafID
        var visited = Set<String>()

        while let current = cursor, let node = nodesByID[current] {
            // A cycle can only come from a corrupt file, but walking one would hang
            // the render loop, so stop at the first repeat.
            guard visited.insert(current).inserted else { break }
            reversed.append(node.entry)
            cursor = node.entry.parentID
        }
        return reversed.reversed()
    }

    /// Every leaf, in file order — the set of branch tips the user can switch between.
    public var leafIDs: [String] {
        entryOrder.filter { nodesByID[$0]?.childIDs.isEmpty ?? false }
    }

    /// The leaf to show when the caller has no better information.
    ///
    /// Matches pi: the last leaf in file order. Verified against a live
    /// `pi --mode rpc` resuming a branching session — it reported the final entry as
    /// the leaf even though an earlier-written entry carried a newer timestamp.
    /// Choosing "newest timestamp" instead would show a different branch than pi
    /// itself considers active, which is exactly the divergence this app must avoid.
    ///
    /// A live session's leaf comes from pi directly (`get_entries` reports `leafId`);
    /// this is only the fallback for a file read off disk.
    public var defaultLeafID: String? {
        leafIDs.last
    }

    /// The active branch, preferring an explicit leaf and otherwise the default one.
    public func activeBranch(leafID: String? = nil) -> [SessionEntry] {
        guard let leaf = leafID ?? defaultLeafID else { return [] }
        return branch(endingAt: leaf)
    }
}

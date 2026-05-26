import Foundation

enum WikiGraphScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case local
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .global: "Global"
        }
    }
}

enum GraphNodeStatus: String, Codable, Sendable {
    case active
    case orphanTarget = "orphan_target"
    case oversized
}

enum GraphHighlightState: String, Codable, Sendable {
    case `default`
    case selected
    case neighbor
    case searchResult = "search_result"
}

struct FilterConfig: Codable, Equatable, Sendable {
    var scope: WikiGraphScope = .global
    var depth: Int = 1
    var selectedNodeID: String?
    var searchTerm: String = ""

    enum CodingKeys: String, CodingKey {
        case scope
        case depth
        case selectedNodeID = "selected_node_id"
        case searchTerm = "search_term"
    }

    var normalized: FilterConfig {
        FilterConfig(
            scope: scope,
            depth: min(10, max(1, depth)),
            selectedNodeID: selectedNodeID,
            searchTerm: String(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        )
    }
}

struct GraphNode: Identifiable, Hashable, Codable, Sendable {
    let nodeID: String
    let label: String
    let path: String
    let folder: String
    let kind: String
    let status: GraphNodeStatus
    let health: WikiHealthClass
    let degreeIn: Int
    let degreeOut: Int
    let truncated: Bool
    let sizeBytes: Int
    let incomingIDs: [String]
    let outgoingIDs: [String]

    var id: String { nodeID }
    var title: String { label }
    var visibleDegree: Int { degreeIn + degreeOut }
    var backlinkCount: Int { degreeIn }
    var outlinkCount: Int { degreeOut }
    var missingLinkCount: Int { status == .orphanTarget ? incomingIDs.count : 0 }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case label
        case path
        case folder
        case kind
        case status
        case health
        case degreeIn = "degree_in"
        case degreeOut = "degree_out"
        case truncated
        case sizeBytes = "size_bytes"
        case incomingIDs = "incoming_ids"
        case outgoingIDs = "outgoing_ids"
    }
}

struct GraphEdge: Identifiable, Hashable, Codable, Sendable {
    let source: String
    let target: String
    let label: String
    let type: String

    var id: String { "\(source)->\(target)" }
    var sourceID: String { source }
    var targetID: String { target }
}

struct FilteredNode: Identifiable, Hashable, Codable, Sendable {
    let base: GraphNode
    let highlight: GraphHighlightState
    let visible: Bool

    var id: String { base.id }
}

struct FilteredSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let filterConfig: FilterConfig
    let nodes: [FilteredNode]
    let edges: [GraphEdge]

    enum CodingKeys: String, CodingKey {
        case version
        case filterConfig = "filter_config"
        case nodes
        case edges
    }
}

struct GraphSnapshot: Codable, Equatable, Sendable {
    static let graphVersion = 1
    static let maxGlobalNodes = 5_000
    static let maxLinksPerNode = 200
    static let oversizedThresholdBytes = 10 * 1_024 * 1_024

    let version: Int
    let selectedNodeID: String?
    let focusNodeID: String?
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let truncated: Bool

    var focusPageID: String? { focusNodeID }
    var selectedPageID: String? { selectedNodeID }

    static let empty = GraphSnapshot(
        version: graphVersion,
        selectedNodeID: nil,
        focusNodeID: nil,
        nodes: [],
        edges: [],
        truncated: false
    )

    enum CodingKeys: String, CodingKey {
        case version
        case selectedNodeID = "selected_node_id"
        case focusNodeID = "focus_node_id"
        case nodes
        case edges
        case truncated
    }

    static func build(index: WikiIndex, selectedPageID: String?) -> GraphSnapshot {
        guard !index.pages.isEmpty else { return .empty }

        let selectedID = index.page(id: selectedPageID)?.id
        let focusID = selectedID ?? index.homePage?.id
        let activePages = orderedActivePages(index: index, focusID: focusID)
        let activeLimit = min(maxGlobalNodes, activePages.count)
        var includedPages = Array(activePages.prefix(activeLimit))

        if let focusID,
           !includedPages.contains(where: { $0.id == focusID }),
           let focusPage = index.page(id: focusID),
           !includedPages.isEmpty {
            includedPages[includedPages.count - 1] = focusPage
        }

        let includedActiveIDs = Set(includedPages.map(\.id))
        let remainingCapacity = max(0, maxGlobalNodes - includedPages.count)
        let orphanNodes = orphanTargetNodes(index: index, includedActiveIDs: includedActiveIDs, limit: remainingCapacity)
        let includedNodeIDs = includedActiveIDs.union(orphanNodes.map(\.nodeID))

        let edgeBuild = buildEdges(index: index, includedActiveIDs: includedActiveIDs, includedNodeIDs: includedNodeIDs)
        let degrees = degreeIndex(edges: edgeBuild.edges)

        let activeNodes = includedPages.map { page in
            makeActiveNode(
                page: page,
                degree: degrees[page.id, default: .empty],
                truncated: edgeBuild.truncatedSourceIDs.contains(page.id)
            )
        }

        let orphanNodesWithDegrees = orphanNodes.map { node in
            makeOrphanNode(node: node, degree: degrees[node.nodeID, default: .empty])
        }

        let nodes = (activeNodes + orphanNodesWithDegrees).sorted(by: graphNodeSort(focusID: focusID))
        let truncated = index.pages.count + orphanNodes.count > nodes.count || edgeBuild.truncatedSourceIDs.isEmpty == false

        return GraphSnapshot(
            version: graphVersion,
            selectedNodeID: selectedID,
            focusNodeID: focusID,
            nodes: nodes,
            edges: edgeBuild.edges,
            truncated: truncated
        )
    }

    static func build(
        index: WikiIndex,
        selectedPageID: String?,
        scope: WikiGraphScope,
        maxNodes: Int,
        depth: Int = 1
    ) -> GraphSnapshot {
        let full = build(index: index, selectedPageID: selectedPageID)
        let filtered = full.filtered(
            using: FilterConfig(scope: scope, depth: depth, selectedNodeID: selectedPageID, searchTerm: ""),
            maxNodes: maxNodes
        )
        return full.replacing(nodes: filtered.nodes.map(\.base), edges: filtered.edges)
    }

    var signature: String {
        [
            "\(version)",
            selectedNodeID ?? "",
            focusNodeID ?? "",
            truncated ? "truncated" : "complete",
            nodes.map(\.nodeID).joined(separator: "|"),
            edges.map(\.id).joined(separator: "|")
        ].joined(separator: "::")
    }

    var nodeByID: [String: GraphNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
    }

    var adjacency: [String: Set<String>] {
        Self.buildAdjacency(edges: edges)
    }

    func adjacentIDs(to pageID: String?) -> Set<String> {
        guard let pageID else { return [] }
        return adjacency[pageID, default: []]
    }

    func filtered(using config: FilterConfig, maxNodes: Int? = nil) -> FilteredSnapshot {
        let normalized = config.normalized
        let allIDs = Set(nodes.map(\.nodeID))
        let visibleIDs: Set<String>

        switch normalized.scope {
        case .global:
            visibleIDs = allIDs
        case .local:
            if let selectedID = normalized.selectedNodeID, allIDs.contains(selectedID) {
                visibleIDs = bfsVisibleIDs(rootID: selectedID, depth: normalized.depth)
            } else {
                visibleIDs = allIDs
            }
        }

        let cappedIDs = cappedVisibleIDs(visibleIDs, selectedID: normalized.selectedNodeID, maxNodes: maxNodes)
        let visibleEdges = edges.filter { cappedIDs.contains($0.source) && cappedIDs.contains($0.target) }
        let directNeighbors = directNeighborIDs(for: normalized.selectedNodeID, edges: edges)
        let term = normalized.searchTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let filteredNodes = nodes
            .filter { cappedIDs.contains($0.nodeID) }
            .map { node in
                FilteredNode(
                    base: node,
                    highlight: highlight(for: node, selectedID: normalized.selectedNodeID, directNeighbors: directNeighbors, searchTerm: term),
                    visible: true
                )
            }

        return FilteredSnapshot(
            version: version,
            filterConfig: normalized,
            nodes: filteredNodes,
            edges: visibleEdges
        )
    }

    private func replacing(nodes: [GraphNode], edges: [GraphEdge]) -> GraphSnapshot {
        GraphSnapshot(
            version: version,
            selectedNodeID: selectedNodeID,
            focusNodeID: focusNodeID,
            nodes: nodes,
            edges: edges,
            truncated: truncated || nodes.count < self.nodes.count || edges.count < self.edges.count
        )
    }

    private func bfsVisibleIDs(rootID: String, depth: Int) -> Set<String> {
        let adjacency = adjacency
        var visited: Set<String> = [rootID]
        var queue: [(String, Int)] = [(rootID, 0)]
        var index = 0

        while index < queue.count {
            let (nodeID, currentDepth) = queue[index]
            index += 1
            guard currentDepth < depth else { continue }

            for neighbor in adjacency[nodeID, default: []] where !visited.contains(neighbor) {
                visited.insert(neighbor)
                queue.append((neighbor, currentDepth + 1))
            }
        }

        return visited
    }

    private func cappedVisibleIDs(_ ids: Set<String>, selectedID: String?, maxNodes: Int?) -> Set<String> {
        guard let maxNodes, ids.count > maxNodes else { return ids }
        let selected = selectedID ?? focusNodeID
        let ordered = nodes
            .filter { ids.contains($0.nodeID) }
            .sorted { lhs, rhs in
                if lhs.nodeID == selected { return true }
                if rhs.nodeID == selected { return false }
                if lhs.visibleDegree != rhs.visibleDegree { return lhs.visibleDegree > rhs.visibleDegree }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        return Set(ordered.prefix(max(1, maxNodes)).map(\.nodeID))
    }

    private func highlight(
        for node: GraphNode,
        selectedID: String?,
        directNeighbors: Set<String>,
        searchTerm: String
    ) -> GraphHighlightState {
        if node.nodeID == selectedID { return .selected }
        if directNeighbors.contains(node.nodeID) { return .neighbor }
        if !searchTerm.isEmpty {
            let label = node.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if label.contains(searchTerm) { return .searchResult }
        }
        return .default
    }

    private static func orderedActivePages(index: WikiIndex, focusID: String?) -> [WikiPage] {
        var pages = index.pages.sorted(by: globalSort)
        if let focusID, let offset = pages.firstIndex(where: { $0.id == focusID }) {
            pages.remove(at: offset)
            pages.insert(index.page(id: focusID)!, at: 0)
        }
        return pages
    }

    private static func globalSort(_ lhs: WikiPage, _ rhs: WikiPage) -> Bool {
        if lhs.connectivityScore != rhs.connectivityScore {
            return lhs.connectivityScore > rhs.connectivityScore
        }
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func orphanTargetNodes(index: WikiIndex, includedActiveIDs: Set<String>, limit: Int) -> [GraphNode] {
        guard limit > 0 else { return [] }

        var candidates: [String: (label: String, path: String, incoming: Set<String>)] = [:]

        for page in index.pages where includedActiveIDs.contains(page.id) {
            for link in page.missingLinks {
                let id = orphanNodeID(for: link)
                let label = link.label.isEmpty ? link.target : link.label
                var current = candidates[id] ?? (label: label, path: link.targetRaw, incoming: [])
                current.incoming.insert(page.id)
                candidates[id] = current
            }
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.value.incoming.count != rhs.value.incoming.count {
                    return lhs.value.incoming.count > rhs.value.incoming.count
                }
                return lhs.value.label.localizedCaseInsensitiveCompare(rhs.value.label) == .orderedAscending
            }
            .prefix(limit)
            .map { id, value in
                GraphNode(
                    nodeID: id,
                    label: value.label,
                    path: value.path,
                    folder: "",
                    kind: "missing",
                    status: .orphanTarget,
                    health: .bad,
                    degreeIn: 0,
                    degreeOut: 0,
                    truncated: false,
                    sizeBytes: 0,
                    incomingIDs: value.incoming.sorted(),
                    outgoingIDs: []
                )
            }
    }

    private static func buildEdges(
        index: WikiIndex,
        includedActiveIDs: Set<String>,
        includedNodeIDs: Set<String>
    ) -> (edges: [GraphEdge], truncatedSourceIDs: Set<String>) {
        var seen: Set<String> = []
        var edges: [GraphEdge] = []
        var truncatedSourceIDs: Set<String> = []

        for page in index.pages where includedActiveIDs.contains(page.id) {
            let links = uniqueGraphTargets(for: page)
            if links.count > maxLinksPerNode {
                truncatedSourceIDs.insert(page.id)
            }

            for target in links.prefix(maxLinksPerNode) where includedNodeIDs.contains(target.id) {
                let edge = GraphEdge(source: page.id, target: target.id, label: target.label, type: target.type)
                if seen.insert(edge.id).inserted {
                    edges.append(edge)
                }
            }
        }

        return (
            edges.sorted {
                if $0.source != $1.source { return $0.source < $1.source }
                return $0.target < $1.target
            },
            truncatedSourceIDs
        )
    }

    private static func uniqueGraphTargets(for page: WikiPage) -> [(id: String, label: String, type: String)] {
        var seen: Set<String> = []
        var targets: [(id: String, label: String, type: String)] = []

        for link in page.outlinks {
            if seen.insert(link.resolvedPageID).inserted {
                targets.append((link.resolvedPageID, link.link.label, "wiki"))
            }
        }

        for link in page.missingLinks {
            let id = orphanNodeID(for: link)
            if seen.insert(id).inserted {
                targets.append((id, link.label, "missing"))
            }
        }

        return targets
    }

    private static func orphanNodeID(for link: WikiLink) -> String {
        let slug = WikiTextParser.slugify(link.target)
        return "missing/\(slug.isEmpty ? "target" : slug)"
    }

    private static func makeActiveNode(page: WikiPage, degree: Degree, truncated: Bool) -> GraphNode {
        GraphNode(
            nodeID: page.id,
            label: page.title,
            path: page.path,
            folder: page.folder,
            kind: page.kind.rawValue,
            status: page.sizeBytes > oversizedThresholdBytes ? .oversized : .active,
            health: page.healthClass,
            degreeIn: degree.incoming.count,
            degreeOut: degree.outgoing.count,
            truncated: truncated,
            sizeBytes: page.sizeBytes,
            incomingIDs: degree.incoming.sorted(),
            outgoingIDs: degree.outgoing.sorted()
        )
    }

    private static func makeOrphanNode(node: GraphNode, degree: Degree) -> GraphNode {
        GraphNode(
            nodeID: node.nodeID,
            label: node.label,
            path: node.path,
            folder: node.folder,
            kind: node.kind,
            status: node.status,
            health: node.health,
            degreeIn: max(node.incomingIDs.count, degree.incoming.count),
            degreeOut: degree.outgoing.count,
            truncated: node.truncated,
            sizeBytes: node.sizeBytes,
            incomingIDs: Array(Set(node.incomingIDs).union(degree.incoming)).sorted(),
            outgoingIDs: degree.outgoing.sorted()
        )
    }

    private static func graphNodeSort(focusID: String?) -> (GraphNode, GraphNode) -> Bool {
        { lhs, rhs in
            if lhs.nodeID == focusID { return true }
            if rhs.nodeID == focusID { return false }
            if lhs.status != rhs.status {
                if lhs.status == .active || lhs.status == .oversized { return true }
                if rhs.status == .active || rhs.status == .oversized { return false }
            }
            if lhs.visibleDegree != rhs.visibleDegree { return lhs.visibleDegree > rhs.visibleDegree }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func degreeIndex(edges: [GraphEdge]) -> [String: Degree] {
        var degrees: [String: Degree] = [:]
        for edge in edges {
            degrees[edge.source, default: .empty].outgoing.insert(edge.target)
            degrees[edge.target, default: .empty].incoming.insert(edge.source)
        }
        return degrees
    }

    private static func buildAdjacency(edges: [GraphEdge]) -> [String: Set<String>] {
        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }
        return adjacency
    }

    private func directNeighborIDs(for selectedID: String?, edges: [GraphEdge]) -> Set<String> {
        guard let selectedID else { return [] }
        var ids: Set<String> = []
        for edge in edges {
            if edge.source == selectedID { ids.insert(edge.target) }
            if edge.target == selectedID { ids.insert(edge.source) }
        }
        return ids
    }
}

private struct Degree: Equatable {
    var incoming: Set<String>
    var outgoing: Set<String>

    static let empty = Degree(incoming: [], outgoing: [])
}

typealias WikiGraphNode = GraphNode
typealias WikiGraphEdge = GraphEdge
typealias WikiGraphSnapshot = GraphSnapshot

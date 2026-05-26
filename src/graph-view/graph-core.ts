export type ScopeMode = "global" | "local";
export type NodeStatus = "active" | "orphan_target" | "oversized";
export type HighlightState = "default" | "selected" | "neighbor" | "search_result";
export type LayoutStatus = "idle" | "running" | "converged" | "timeout" | "cancelled" | "error";

export interface GraphNode {
  node_id: string;
  label: string;
  path: string;
  folder: string;
  kind: string;
  status: NodeStatus;
  health: "good" | "warn" | "bad";
  degree_in: number;
  degree_out: number;
  truncated: boolean;
  size_bytes: number;
  incoming_ids: string[];
  outgoing_ids: string[];
}

export interface GraphEdge {
  source: string;
  target: string;
  label: string;
  type: string;
}

export interface GraphSnapshot {
  version: number;
  selected_node_id: string | null;
  focus_node_id: string | null;
  nodes: GraphNode[];
  edges: GraphEdge[];
  truncated: boolean;
}

export interface FilterConfig {
  scope: ScopeMode;
  depth: number;
  selected_node_id: string | null;
  search_term: string;
}

export interface FilteredNode extends GraphNode {
  highlight: HighlightState;
  visible: boolean;
}

export interface FilteredSnapshot {
  version: number;
  filter_config: FilterConfig;
  nodes: FilteredNode[];
  edges: GraphEdge[];
}

export interface Viewport {
  x: number;
  y: number;
  zoom: number;
  width?: number;
  height?: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface PositionedNode extends FilteredNode {
  x: number;
  y: number;
  radius: number;
}

export const GRAPH_LIMITS = {
  maxVisibleNodes: 500,
  maxGlobalNodes: 5000,
  maxDepth: 10,
  maxSearchChars: 200,
  worldMin: -5000,
  worldMax: 5000
} as const;

export const GRAPH_COLORS = {
  background: "#080a0d",
  grid: "rgba(47, 47, 47, 0.36)",
  edge: "rgba(47, 47, 47, 0.55)",
  edgeActive: "rgba(149, 149, 149, 0.75)",
  text: "#d7d7d7",
  dim: "#959595",
  defaultNode: "#2F2F2F",
  selectedNode: "#959595",
  neighborNode: "#2F2F2F",
  isolatedNode: "#2F2F2F",
  oversizedNode: "#2F2F2F",
  searchNode: "#2F2F2F"
} as const;

export function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

export function normalizeSearchTerm(term: string | null | undefined): string {
  return String(term ?? "").trim().slice(0, GRAPH_LIMITS.maxSearchChars).toLocaleLowerCase();
}

export function normalizeFilter(config: Partial<FilterConfig> | null | undefined): FilterConfig {
  const scope = config?.scope === "local" ? "local" : "global";
  return {
    scope,
    depth: clamp(Math.round(Number(config?.depth ?? 1) || 1), 1, GRAPH_LIMITS.maxDepth),
    selected_node_id: config?.selected_node_id || null,
    search_term: normalizeSearchTerm(config?.search_term)
  };
}

export function hashString(value: string): number {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

export function makeRng(seedValue: string): () => number {
  let state = hashString(seedValue) || 1;
  return () => {
    state += 0x6d2b79f5;
    let next = state;
    next = Math.imul(next ^ (next >>> 15), next | 1);
    next ^= next + Math.imul(next ^ (next >>> 7), next | 61);
    return ((next ^ (next >>> 14)) >>> 0) / 4294967296;
  };
}

export function buildAdjacency(edges: GraphEdge[]): Map<string, Set<string>> {
  const adjacency = new Map<string, Set<string>>();
  for (const edge of edges) {
    if (!adjacency.has(edge.source)) adjacency.set(edge.source, new Set());
    if (!adjacency.has(edge.target)) adjacency.set(edge.target, new Set());
    adjacency.get(edge.source)!.add(edge.target);
    adjacency.get(edge.target)!.add(edge.source);
  }
  return adjacency;
}

export function directNeighborIds(selectedId: string | null, edges: GraphEdge[]): Set<string> {
  const ids = new Set<string>();
  if (!selectedId) return ids;
  for (const edge of edges) {
    if (edge.source === selectedId) ids.add(edge.target);
    if (edge.target === selectedId) ids.add(edge.source);
  }
  return ids;
}

export function bfsVisibleIds(rootId: string, edges: GraphEdge[], maxDepth: number): Set<string> {
  const adjacency = buildAdjacency(edges);
  const visited = new Set<string>([rootId]);
  const queue: Array<[string, number]> = [[rootId, 0]];

  for (let index = 0; index < queue.length; index += 1) {
    const [nodeId, depth] = queue[index];
    if (depth >= maxDepth) continue;
    for (const neighbor of adjacency.get(nodeId) ?? []) {
      if (!visited.has(neighbor)) {
        visited.add(neighbor);
        queue.push([neighbor, depth + 1]);
      }
    }
  }

  return visited;
}

export function applyFilter(
  graph: GraphSnapshot,
  filter: Partial<FilterConfig> | null | undefined,
  maxVisibleNodes = GRAPH_LIMITS.maxVisibleNodes
): FilteredSnapshot {
  const config = normalizeFilter(filter);
  const nodeIds = new Set(graph.nodes.map((node) => node.node_id));
  let visibleIds: Set<string>;

  if (config.scope === "local" && config.selected_node_id && nodeIds.has(config.selected_node_id)) {
    visibleIds = bfsVisibleIds(config.selected_node_id, graph.edges, config.depth);
  } else {
    visibleIds = new Set(nodeIds);
  }

  if (visibleIds.size > maxVisibleNodes) {
    visibleIds = capVisibleIds(graph.nodes, visibleIds, config.selected_node_id, maxVisibleNodes);
  }

  const visibleEdges = graph.edges.filter((edge) => visibleIds.has(edge.source) && visibleIds.has(edge.target));
  const neighbors = directNeighborIds(config.selected_node_id, graph.edges);
  const filteredNodes = graph.nodes
    .filter((node) => visibleIds.has(node.node_id))
    .map((node) => ({
      ...node,
      highlight: highlightForNode(node, config.selected_node_id, neighbors, config.search_term),
      visible: true
    }));

  return {
    version: graph.version,
    filter_config: config,
    nodes: filteredNodes,
    edges: visibleEdges
  };
}

export function searchNodes(graph: GraphSnapshot, rawTerm: string): GraphNode[] {
  const term = normalizeSearchTerm(rawTerm);
  if (!term) return [];
  return graph.nodes.filter((node) => node.label.toLocaleLowerCase().includes(term));
}

export function capVisibleIds(
  nodes: GraphNode[],
  visibleIds: Set<string>,
  selectedId: string | null,
  maxVisibleNodes: number
): Set<string> {
  const ordered = nodes
    .filter((node) => visibleIds.has(node.node_id))
    .sort((a, b) => {
      if (a.node_id === selectedId) return -1;
      if (b.node_id === selectedId) return 1;
      const degreeDiff = nodeDegree(b) - nodeDegree(a);
      if (degreeDiff !== 0) return degreeDiff;
      return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
    });

  return new Set(ordered.slice(0, Math.max(1, maxVisibleNodes)).map((node) => node.node_id));
}

export function highlightForNode(
  node: GraphNode,
  selectedId: string | null,
  directNeighbors: Set<string>,
  searchTerm: string
): HighlightState {
  if (node.node_id === selectedId) return "selected";
  if (directNeighbors.has(node.node_id)) return "neighbor";
  if (searchTerm && node.label.toLocaleLowerCase().includes(searchTerm)) return "search_result";
  return "default";
}

export function nodeDegree(node: Pick<GraphNode, "degree_in" | "degree_out">): number {
  return Math.max(0, Number(node.degree_in || 0) + Number(node.degree_out || 0));
}

export function nodeRadius(node: Pick<GraphNode, "degree_in" | "degree_out" | "status">): number {
  const degree = nodeDegree(node);
  const base = node.status === "orphan_target" ? 3.8 : 4.6;
  return clamp(base + Math.sqrt(degree + 1) * 1.75, 4, 18);
}

export function stableInitialPosition(
  node: Pick<GraphNode, "node_id" | "folder" | "degree_in" | "degree_out">,
  index: number,
  total: number,
  selectedId: string | null
): Point {
  if (node.node_id === selectedId) return { x: 0, y: 0 };

  const folderHash = hashString(node.folder || "root");
  const nodeHash = hashString(node.node_id);
  const folderAngle = (folderHash / 4294967296) * Math.PI * 2;
  const offset = ((nodeHash % 1024) / 1024 - 0.5) * 0.92;
  const angle = folderAngle + offset;
  const degree = nodeDegree(node);
  const ring = 180 + Math.sqrt(index + 1) * 34 + Math.min(260, total * 0.34);
  const hubPull = clamp(degree * 7, 0, 180);
  const radius = clamp(ring - hubPull, 80, 1600);

  return {
    x: Math.cos(angle) * radius,
    y: Math.sin(angle) * radius
  };
}

export function worldToScreen(point: Point, viewport: Viewport): Point {
  return {
    x: viewport.x + point.x * viewport.zoom,
    y: viewport.y + point.y * viewport.zoom
  };
}

export function screenToWorld(point: Point, viewport: Viewport): Point {
  return {
    x: (point.x - viewport.x) / viewport.zoom,
    y: (point.y - viewport.y) / viewport.zoom
  };
}

export function hitTest(nodes: PositionedNode[], viewport: Viewport, screen: Point): PositionedNode | null {
  let best: PositionedNode | null = null;
  let bestScore = -Infinity;

  for (const node of nodes) {
    const point = worldToScreen(node, viewport);
    const radius = Math.max(9, node.radius * viewport.zoom + 6);
    const dx = screen.x - point.x;
    const dy = screen.y - point.y;
    const distance = Math.sqrt(dx * dx + dy * dy);
    if (distance > radius) continue;

    const score = node.degree_in * 1000 + nodeDegree(node) * 20 - distance;
    if (score > bestScore) {
      best = node;
      bestScore = score;
    }
  }

  return best;
}

export function graphBounds(nodes: Array<Point>): { minX: number; minY: number; maxX: number; maxY: number } {
  if (nodes.length === 0) return { minX: -100, minY: -100, maxX: 100, maxY: 100 };
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of nodes) {
    minX = Math.min(minX, node.x);
    minY = Math.min(minY, node.y);
    maxX = Math.max(maxX, node.x);
    maxY = Math.max(maxY, node.y);
  }

  return { minX, minY, maxX, maxY };
}

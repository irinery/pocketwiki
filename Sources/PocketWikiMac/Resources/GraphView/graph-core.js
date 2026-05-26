// src/graph-view/graph-core.ts
var GRAPH_LIMITS = {
  maxVisibleNodes: 500,
  maxGlobalNodes: 5e3,
  maxDepth: 10,
  maxSearchChars: 200,
  worldMin: -5e3,
  worldMax: 5e3
};
var GRAPH_COLORS = {
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
};
function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
function normalizeSearchTerm(term) {
  return String(term ?? "").trim().slice(0, GRAPH_LIMITS.maxSearchChars).toLocaleLowerCase();
}
function normalizeFilter(config) {
  const scope = config?.scope === "local" ? "local" : "global";
  return {
    scope,
    depth: clamp(Math.round(Number(config?.depth ?? 1) || 1), 1, GRAPH_LIMITS.maxDepth),
    selected_node_id: config?.selected_node_id || null,
    search_term: normalizeSearchTerm(config?.search_term)
  };
}
function hashString(value) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}
function makeRng(seedValue) {
  let state = hashString(seedValue) || 1;
  return () => {
    state += 1831565813;
    let next = state;
    next = Math.imul(next ^ next >>> 15, next | 1);
    next ^= next + Math.imul(next ^ next >>> 7, next | 61);
    return ((next ^ next >>> 14) >>> 0) / 4294967296;
  };
}
function buildAdjacency(edges) {
  const adjacency = /* @__PURE__ */ new Map();
  for (const edge of edges) {
    if (!adjacency.has(edge.source)) adjacency.set(edge.source, /* @__PURE__ */ new Set());
    if (!adjacency.has(edge.target)) adjacency.set(edge.target, /* @__PURE__ */ new Set());
    adjacency.get(edge.source).add(edge.target);
    adjacency.get(edge.target).add(edge.source);
  }
  return adjacency;
}
function directNeighborIds(selectedId, edges) {
  const ids = /* @__PURE__ */ new Set();
  if (!selectedId) return ids;
  for (const edge of edges) {
    if (edge.source === selectedId) ids.add(edge.target);
    if (edge.target === selectedId) ids.add(edge.source);
  }
  return ids;
}
function bfsVisibleIds(rootId, edges, maxDepth) {
  const adjacency = buildAdjacency(edges);
  const visited = /* @__PURE__ */ new Set([rootId]);
  const queue = [[rootId, 0]];
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
function applyFilter(graph, filter, maxVisibleNodes = GRAPH_LIMITS.maxVisibleNodes) {
  const config = normalizeFilter(filter);
  const nodeIds = new Set(graph.nodes.map((node) => node.node_id));
  let visibleIds;
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
  const filteredNodes = graph.nodes.filter((node) => visibleIds.has(node.node_id)).map((node) => ({
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
function searchNodes(graph, rawTerm) {
  const term = normalizeSearchTerm(rawTerm);
  if (!term) return [];
  return graph.nodes.filter((node) => node.label.toLocaleLowerCase().includes(term));
}
function capVisibleIds(nodes, visibleIds, selectedId, maxVisibleNodes) {
  const ordered = nodes.filter((node) => visibleIds.has(node.node_id)).sort((a, b) => {
    if (a.node_id === selectedId) return -1;
    if (b.node_id === selectedId) return 1;
    const degreeDiff = nodeDegree(b) - nodeDegree(a);
    if (degreeDiff !== 0) return degreeDiff;
    return a.label.localeCompare(b.label, void 0, { sensitivity: "base" });
  });
  return new Set(ordered.slice(0, Math.max(1, maxVisibleNodes)).map((node) => node.node_id));
}
function highlightForNode(node, selectedId, directNeighbors, searchTerm) {
  if (node.node_id === selectedId) return "selected";
  if (directNeighbors.has(node.node_id)) return "neighbor";
  if (searchTerm && node.label.toLocaleLowerCase().includes(searchTerm)) return "search_result";
  return "default";
}
function nodeDegree(node) {
  return Math.max(0, Number(node.degree_in || 0) + Number(node.degree_out || 0));
}
function nodeRadius(node) {
  const degree = nodeDegree(node);
  const base = node.status === "orphan_target" ? 3.8 : 4.6;
  return clamp(base + Math.sqrt(degree + 1) * 1.75, 4, 18);
}
function stableInitialPosition(node, index, total, selectedId) {
  if (node.node_id === selectedId) return { x: 0, y: 0 };
  const folderHash = hashString(node.folder || "root");
  const nodeHash = hashString(node.node_id);
  const folderAngle = folderHash / 4294967296 * Math.PI * 2;
  const offset = (nodeHash % 1024 / 1024 - 0.5) * 0.92;
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
function worldToScreen(point, viewport) {
  return {
    x: viewport.x + point.x * viewport.zoom,
    y: viewport.y + point.y * viewport.zoom
  };
}
function screenToWorld(point, viewport) {
  return {
    x: (point.x - viewport.x) / viewport.zoom,
    y: (point.y - viewport.y) / viewport.zoom
  };
}
function hitTest(nodes, viewport, screen) {
  let best = null;
  let bestScore = -Infinity;
  for (const node of nodes) {
    const point = worldToScreen(node, viewport);
    const radius = Math.max(9, node.radius * viewport.zoom + 6);
    const dx = screen.x - point.x;
    const dy = screen.y - point.y;
    const distance = Math.sqrt(dx * dx + dy * dy);
    if (distance > radius) continue;
    const score = node.degree_in * 1e3 + nodeDegree(node) * 20 - distance;
    if (score > bestScore) {
      best = node;
      bestScore = score;
    }
  }
  return best;
}
function graphBounds(nodes) {
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
export {
  GRAPH_COLORS,
  GRAPH_LIMITS,
  applyFilter,
  bfsVisibleIds,
  buildAdjacency,
  capVisibleIds,
  clamp,
  directNeighborIds,
  graphBounds,
  hashString,
  highlightForNode,
  hitTest,
  makeRng,
  nodeDegree,
  nodeRadius,
  normalizeFilter,
  normalizeSearchTerm,
  screenToWorld,
  searchNodes,
  stableInitialPosition,
  worldToScreen
};

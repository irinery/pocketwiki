(() => {
  var __defProp = Object.defineProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

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
    grid: "rgba(51, 66, 86, 0.13)",
    edge: "rgba(134, 239, 172, 0.11)",
    edgeActive: "rgba(134, 239, 172, 0.58)",
    text: "#e7edf5",
    dim: "#93a1b5",
    defaultNode: "#4ade80",
    selectedNode: "#f59e0b",
    neighborNode: "#86efac",
    isolatedNode: "#6b7280",
    oversizedNode: "#ef4444",
    searchNode: "#72d6ff"
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

  // src/graph-view/renderer.ts
  var GraphRenderer = class {
    constructor(canvas2) {
      __publicField(this, "canvas");
      __publicField(this, "ctx");
      __publicField(this, "nodes", []);
      __publicField(this, "edges", []);
      __publicField(this, "nodeById", /* @__PURE__ */ new Map());
      __publicField(this, "selectedId", null);
      __publicField(this, "hoverId", null);
      __publicField(this, "raf", 0);
      __publicField(this, "viewport", { x: 0, y: 0, zoom: 1, width: 1, height: 1 });
      __publicField(this, "dpr", 1);
      this.canvas = canvas2;
      const ctx = canvas2.getContext("2d", { alpha: false });
      if (!ctx) throw new Error("Canvas 2D indisponivel");
      this.ctx = ctx;
      this.resize();
    }
    setSnapshot(snapshot, selectedId) {
      const previous = this.nodeById;
      this.selectedId = selectedId;
      this.hoverId = null;
      this.nodes = snapshot.nodes.map((node, index) => {
        const old = previous.get(node.node_id);
        const initial = old ?? stableInitialPosition(node, index, snapshot.nodes.length, selectedId);
        return {
          ...node,
          x: initial.x,
          y: initial.y,
          targetX: old?.targetX ?? initial.x,
          targetY: old?.targetY ?? initial.y,
          radius: nodeRadius(node)
        };
      });
      this.nodeById = new Map(this.nodes.map((node) => [node.node_id, node]));
      this.edges = snapshot.edges.map((edge) => {
        const source = this.nodeById.get(edge.source);
        const target = this.nodeById.get(edge.target);
        return source && target ? { source, target, type: edge.type } : null;
      }).filter((edge) => Boolean(edge));
      if (previous.size === 0 || snapshot.filter_config.scope === "local") {
        this.fitToGraph();
      }
      this.requestDraw();
    }
    updateLayout(layoutNodes) {
      for (const layoutNode of layoutNodes) {
        const node = this.nodeById.get(layoutNode.id);
        if (!node) continue;
        if (Number.isFinite(layoutNode.x) && Number.isFinite(layoutNode.y)) {
          node.targetX = layoutNode.x;
          node.targetY = layoutNode.y;
        }
      }
      this.requestDraw();
    }
    updateNodePosition(id, point) {
      const node = this.nodeById.get(id);
      if (!node) return;
      node.x = point.x;
      node.y = point.y;
      node.targetX = point.x;
      node.targetY = point.y;
      this.requestDraw();
    }
    resize() {
      const rect = this.canvas.getBoundingClientRect();
      this.dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
      this.viewport.width = Math.max(1, rect.width);
      this.viewport.height = Math.max(1, rect.height);
      this.canvas.width = Math.floor(this.viewport.width * this.dpr);
      this.canvas.height = Math.floor(this.viewport.height * this.dpr);
      this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      if (this.viewport.x === 0 && this.viewport.y === 0) {
        this.viewport.x = this.viewport.width / 2;
        this.viewport.y = this.viewport.height / 2;
      }
      this.requestDraw();
    }
    fitToGraph() {
      const bounds = graphBounds(this.nodes);
      const width = Math.max(1, bounds.maxX - bounds.minX);
      const height = Math.max(1, bounds.maxY - bounds.minY);
      const zoomX = this.viewport.width * 0.78 / width;
      const zoomY = this.viewport.height * 0.78 / height;
      this.viewport.zoom = Math.min(1.08, Math.max(0.18, Math.min(zoomX, zoomY)));
      const cx = (bounds.minX + bounds.maxX) / 2;
      const cy = (bounds.minY + bounds.maxY) / 2;
      this.viewport.x = this.viewport.width / 2 - cx * this.viewport.zoom;
      this.viewport.y = this.viewport.height / 2 - cy * this.viewport.zoom;
      this.requestDraw();
    }
    centerOn(id) {
      const node = this.nodeById.get(id);
      if (!node) return;
      this.viewport.x = this.viewport.width / 2 - node.x * this.viewport.zoom;
      this.viewport.y = this.viewport.height / 2 - node.y * this.viewport.zoom;
      this.requestDraw();
    }
    panBy(dx, dy) {
      this.viewport.x += dx;
      this.viewport.y += dy;
      this.requestDraw();
    }
    zoomAt(screen, factor) {
      const before = this.screenToWorld(screen);
      this.viewport.zoom = Math.max(0.12, Math.min(3.2, this.viewport.zoom * factor));
      this.viewport.x = screen.x - before.x * this.viewport.zoom;
      this.viewport.y = screen.y - before.y * this.viewport.zoom;
      this.requestDraw();
    }
    setHover(id) {
      if (this.hoverId === id) return;
      this.hoverId = id;
      this.requestDraw();
    }
    setSelected(id) {
      if (this.selectedId === id) return;
      this.selectedId = id;
      this.requestDraw();
    }
    getNodeAt(screen) {
      return hitTest(this.nodes, this.viewport, screen);
    }
    getNode(id) {
      return id ? this.nodeById.get(id) ?? null : null;
    }
    getNodes() {
      return this.nodes;
    }
    screenToWorld(point) {
      return screenToWorld(point, this.viewport);
    }
    requestDraw() {
      if (this.raf) return;
      this.raf = requestAnimationFrame(() => {
        this.raf = 0;
        const moving = this.stepVisualPositions();
        this.draw();
        if (moving) this.requestDraw();
      });
    }
    stepVisualPositions() {
      let moving = false;
      for (const node of this.nodes) {
        const dx = node.targetX - node.x;
        const dy = node.targetY - node.y;
        if (Math.abs(dx) < 0.08 && Math.abs(dy) < 0.08) {
          node.x = node.targetX;
          node.y = node.targetY;
          continue;
        }
        node.x += dx * 0.22;
        node.y += dy * 0.22;
        moving = true;
      }
      return moving;
    }
    draw() {
      const ctx = this.ctx;
      ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      ctx.fillStyle = GRAPH_COLORS.background;
      ctx.fillRect(0, 0, this.viewport.width, this.viewport.height);
      this.drawGrid(ctx);
      const activeIds = this.activeIds();
      for (const edge of this.edges) this.drawEdge(ctx, edge, activeIds);
      for (const node of this.nodes) this.drawNode(ctx, node, activeIds);
      this.drawLabels(ctx, activeIds);
    }
    drawGrid(ctx) {
      const step = 64 * this.viewport.zoom;
      if (step < 22) return;
      const offsetX = (this.viewport.x % step + step) % step;
      const offsetY = (this.viewport.y % step + step) % step;
      ctx.strokeStyle = GRAPH_COLORS.grid;
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let x = offsetX; x < this.viewport.width; x += step) {
        ctx.moveTo(x, 0);
        ctx.lineTo(x, this.viewport.height);
      }
      for (let y = offsetY; y < this.viewport.height; y += step) {
        ctx.moveTo(0, y);
        ctx.lineTo(this.viewport.width, y);
      }
      ctx.stroke();
    }
    drawEdge(ctx, edge, activeIds) {
      const source = worldToScreen(edge.source, this.viewport);
      const target = worldToScreen(edge.target, this.viewport);
      if (!this.segmentVisible(source, target, 80)) return;
      const focusId = this.hoverId || this.selectedId;
      const active = !focusId || edge.source.node_id === focusId || edge.target.node_id === focusId;
      ctx.globalAlpha = active ? 1 : 0.22;
      ctx.strokeStyle = active ? GRAPH_COLORS.edgeActive : GRAPH_COLORS.edge;
      ctx.lineWidth = active ? 1.15 : 0.55;
      ctx.beginPath();
      ctx.moveTo(source.x, source.y);
      ctx.lineTo(target.x, target.y);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    drawNode(ctx, node, activeIds) {
      const point = worldToScreen(node, this.viewport);
      const radius = Math.max(2.6, node.radius * this.viewport.zoom);
      if (!this.pointVisible(point, radius + 24)) return;
      const selected = node.node_id === this.selectedId;
      const hovered = node.node_id === this.hoverId;
      const active = activeIds.size === 0 || activeIds.has(node.node_id);
      const color = this.nodeColor(node);
      if (nodeDegree(node) >= 12 || selected || hovered) {
        ctx.globalAlpha = selected || hovered ? 0.48 : 0.18;
        ctx.fillStyle = selected ? GRAPH_COLORS.selectedNode : color;
        ctx.beginPath();
        ctx.arc(point.x, point.y, radius + (selected ? 12 : 8), 0, Math.PI * 2);
        ctx.fill();
        ctx.globalAlpha = 1;
      }
      ctx.globalAlpha = active ? 1 : 0.28;
      const gradient = ctx.createRadialGradient(point.x - radius * 0.25, point.y - radius * 0.35, 1, point.x, point.y, radius);
      gradient.addColorStop(0, color);
      gradient.addColorStop(1, "rgba(74, 222, 128, 0.18)");
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.strokeStyle = selected ? GRAPH_COLORS.selectedNode : "rgba(231, 237, 245, 0.24)";
      ctx.lineWidth = selected ? 2 : 0.85;
      ctx.beginPath();
      ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
      ctx.stroke();
    }
    drawLabels(ctx, activeIds) {
      if (this.viewport.zoom < 0.3) return;
      const candidates = this.nodes.filter((node) => this.shouldLabel(node, activeIds)).sort((a, b) => {
        const selectedA = a.node_id === this.selectedId || a.node_id === this.hoverId ? 1 : 0;
        const selectedB = b.node_id === this.selectedId || b.node_id === this.hoverId ? 1 : 0;
        if (selectedA !== selectedB) return selectedB - selectedA;
        return nodeDegree(b) - nodeDegree(a);
      }).slice(0, this.viewport.zoom > 1.15 ? 110 : 60);
      const occupied = [];
      for (const node of candidates) {
        const point = worldToScreen(node, this.viewport);
        if (!this.pointVisible(point, 80)) continue;
        const prominent = node.node_id === this.selectedId || node.node_id === this.hoverId || node.highlight === "search_result";
        const box = this.labelBox(ctx, node, point, prominent);
        if (!prominent && occupied.some((item) => boxesOverlap(item, box))) continue;
        this.drawLabel(ctx, node, point, prominent, box);
        occupied.push(box);
      }
    }
    labelBox(ctx, node, point, prominent) {
      const text = node.label.length > 44 ? `${node.label.slice(0, 41)}...` : node.label;
      const fontSize = prominent ? 12 : 10.5;
      ctx.font = `${prominent ? 700 : 500} ${fontSize}px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif`;
      const width = ctx.measureText(text).width;
      const x = point.x - width / 2;
      const y = point.y + node.radius * this.viewport.zoom + 12;
      return { x: x - 6, y: y - 3, width: width + 12, height: fontSize + 8 };
    }
    drawLabel(ctx, node, point, prominent, box) {
      const text = node.label.length > 44 ? `${node.label.slice(0, 41)}...` : node.label;
      const fontSize = prominent ? 12 : 10.5;
      const x = box.x + 6;
      const y = box.y + 3;
      ctx.font = `${prominent ? 700 : 500} ${fontSize}px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif`;
      if (prominent) {
        ctx.fillStyle = "rgba(8, 10, 13, 0.82)";
        roundRect(ctx, box.x, box.y, box.width, box.height, 7);
        ctx.fill();
        ctx.strokeStyle = "rgba(51, 66, 86, 0.72)";
        ctx.stroke();
      }
      ctx.fillStyle = prominent ? GRAPH_COLORS.text : GRAPH_COLORS.dim;
      ctx.fillText(text, x, y + fontSize);
    }
    shouldLabel(node, activeIds) {
      if (node.node_id === this.selectedId || node.node_id === this.hoverId) return true;
      if (node.highlight === "search_result") return true;
      if (this.viewport.zoom > 0.5 && activeIds.has(node.node_id)) return true;
      if (this.viewport.zoom > 0.72 && nodeDegree(node) >= 10) return true;
      if (this.viewport.zoom > 1.18 && nodeDegree(node) >= 3) return true;
      return this.viewport.zoom > 1.65;
    }
    activeIds() {
      const id = this.hoverId || this.selectedId;
      if (!id) return /* @__PURE__ */ new Set();
      const ids = /* @__PURE__ */ new Set([id]);
      for (const edge of this.edges) {
        if (edge.source.node_id === id) ids.add(edge.target.node_id);
        if (edge.target.node_id === id) ids.add(edge.source.node_id);
      }
      return ids;
    }
    nodeColor(node) {
      if (node.highlight === "selected") return GRAPH_COLORS.selectedNode;
      if (node.highlight === "search_result") return GRAPH_COLORS.searchNode;
      if (node.status === "oversized") return GRAPH_COLORS.oversizedNode;
      if (node.status === "orphan_target") return GRAPH_COLORS.isolatedNode;
      if (node.highlight === "neighbor") return GRAPH_COLORS.neighborNode;
      if (nodeDegree(node) === 0) return GRAPH_COLORS.isolatedNode;
      return GRAPH_COLORS.defaultNode;
    }
    pointVisible(point, margin) {
      return point.x >= -margin && point.y >= -margin && point.x <= this.viewport.width + margin && point.y <= this.viewport.height + margin;
    }
    segmentVisible(a, b, margin) {
      const minX = Math.min(a.x, b.x);
      const maxX = Math.max(a.x, b.x);
      const minY = Math.min(a.y, b.y);
      const maxY = Math.max(a.y, b.y);
      return maxX >= -margin && maxY >= -margin && minX <= this.viewport.width + margin && minY <= this.viewport.height + margin;
    }
  };
  function roundRect(context, x, y, width, height, radius) {
    context.beginPath();
    context.moveTo(x + radius, y);
    context.arcTo(x + width, y, x + width, y + height, radius);
    context.arcTo(x + width, y + height, x, y + height, radius);
    context.arcTo(x, y + height, x, y, radius);
    context.arcTo(x, y, x + width, y, radius);
    context.closePath();
  }
  function boxesOverlap(a, b) {
    return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
  }

  // src/graph-view/main.ts
  var canvas = document.getElementById("graph");
  var statusEl = document.getElementById("status");
  var detailTitle = document.getElementById("detail-title");
  var detailMeta = document.getElementById("detail-meta");
  var detailLinks = document.getElementById("detail-links");
  if (!canvas) {
    throw new Error("Canvas do grafo nao encontrado");
  }
  var renderer = new GraphRenderer(canvas);
  var state = {
    graph: null,
    filter: null,
    filtered: null,
    worker: null,
    requestId: 0,
    draggingNode: null,
    dragMoved: false,
    panning: null,
    lastPointer: null,
    pinned: /* @__PURE__ */ new Map(),
    pointers: /* @__PURE__ */ new Map(),
    pinchDistance: 0,
    pendingCenterId: null
  };
  function post(type, payload = {}) {
    try {
      window.webkit?.messageHandlers?.pocketwikiGraph?.postMessage({ type, ...payload });
    } catch {
    }
  }
  function setStatus(text) {
    if (statusEl) statusEl.textContent = text;
  }
  function receive(payload) {
    if (!payload || payload.command !== "setGraph") return;
    state.graph = payload.graph;
    state.filter = payload.filter;
    state.filtered = applyFilter(payload.graph, payload.filter, 500);
    const selectedId = state.filtered.filter_config.selected_node_id;
    renderer.setSnapshot(state.filtered, selectedId);
    updateDetails(renderer.getNode(selectedId));
    maybeQueueSearchCenter(payload.graph, payload.filter);
    startLayout();
  }
  function maybeQueueSearchCenter(graph, filter) {
    const results = searchNodes(graph, filter.search_term || "");
    state.pendingCenterId = results.length === 1 ? results[0].node_id : null;
  }
  function startLayout() {
    const filtered = state.filtered;
    if (!filtered) return;
    state.requestId += 1;
    const requestId = state.requestId;
    if (state.worker) {
      state.worker.postMessage({ type: "cancel" });
      state.worker.terminate();
      state.worker = null;
    }
    try {
      const worker = new Worker("./layout-worker.js", { type: "module" });
      state.worker = worker;
      worker.onmessage = (event) => handleLayoutMessage(event.data);
      worker.onerror = (event) => {
        setStatus("layout indisponivel");
        post("diagnostic", { message: event.message || "erro no worker de layout" });
      };
      worker.postMessage({
        type: "start",
        requestId,
        selectedId: filtered.filter_config.selected_node_id,
        nodes: filtered.nodes.map((node) => ({
          id: node.node_id,
          label: node.label,
          folder: node.folder,
          status: node.status,
          degree_in: node.degree_in,
          degree_out: node.degree_out,
          highlight: node.highlight
        })),
        edges: filtered.edges.map((edge) => ({ source: edge.source, target: edge.target })),
        pinned: Object.fromEntries(state.pinned)
      });
      setStatus("layout rodando");
    } catch (error) {
      setStatus("layout falhou");
      post("diagnostic", { message: error instanceof Error ? error.message : String(error) });
    }
  }
  function handleLayoutMessage(message) {
    if (message.requestId !== state.requestId) return;
    if (message.status === "error") {
      setStatus("layout com erro");
      post("diagnostic", { message: message.message || "erro no layout" });
      return;
    }
    renderer.updateLayout(message.nodes.map((node) => {
      const pinned = state.pinned.get(node.id);
      return pinned ? { id: node.id, x: pinned.x, y: pinned.y } : node;
    }));
    if (state.pendingCenterId) {
      renderer.centerOn(state.pendingCenterId);
      state.pendingCenterId = null;
    }
    if (message.status !== "running") {
      setStatus(message.status === "timeout" ? "layout parcial" : "layout pronto");
    }
    post("layoutStatus", { status: message.status, iteration: message.iteration });
  }
  function updateDetails(node) {
    if (!detailTitle || !detailMeta || !detailLinks) return;
    if (!node) {
      detailTitle.textContent = "Nenhum no selecionado";
      detailMeta.textContent = "";
      detailLinks.textContent = "";
      return;
    }
    detailTitle.textContent = node.label;
    detailMeta.textContent = `${node.degree_in} backlinks / ${node.degree_out} outlinks`;
    const incoming = node.incoming_ids.slice(0, 8).join(", ");
    const outgoing = node.outgoing_ids.slice(0, 8).join(", ");
    detailLinks.textContent = [incoming && `in: ${incoming}`, outgoing && `out: ${outgoing}`].filter(Boolean).join(" | ");
  }
  function screenPoint(event) {
    const rect = canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }
  function pointerMoved(a, b) {
    if (!a) return false;
    return Math.hypot(a.x - b.x, a.y - b.y) > 4;
  }
  canvas.addEventListener("pointerdown", (event) => {
    canvas.setPointerCapture(event.pointerId);
    const point = screenPoint(event);
    state.pointers.set(event.pointerId, point);
    state.lastPointer = point;
    state.dragMoved = false;
    if (state.pointers.size === 2) {
      const values = Array.from(state.pointers.values());
      state.pinchDistance = Math.hypot(values[0].x - values[1].x, values[0].y - values[1].y);
      state.draggingNode = null;
      state.panning = null;
      return;
    }
    const node = renderer.getNodeAt(point);
    if (node) {
      state.draggingNode = node;
      state.panning = null;
      canvas.style.cursor = "grabbing";
    } else {
      state.draggingNode = null;
      state.panning = point;
      canvas.style.cursor = "grabbing";
    }
  });
  canvas.addEventListener("pointermove", (event) => {
    const point = screenPoint(event);
    state.pointers.set(event.pointerId, point);
    if (state.pointers.size === 2) {
      const values = Array.from(state.pointers.values());
      const distance = Math.hypot(values[0].x - values[1].x, values[0].y - values[1].y);
      if (state.pinchDistance > 0) {
        const midpoint = { x: (values[0].x + values[1].x) / 2, y: (values[0].y + values[1].y) / 2 };
        renderer.zoomAt(midpoint, distance / state.pinchDistance);
      }
      state.pinchDistance = distance;
      return;
    }
    if (state.draggingNode) {
      state.dragMoved = state.dragMoved || pointerMoved(state.lastPointer, point);
      const world = renderer.screenToWorld(point);
      state.pinned.set(state.draggingNode.node_id, world);
      renderer.updateNodePosition(state.draggingNode.node_id, world);
      return;
    }
    if (state.panning && state.lastPointer) {
      state.dragMoved = state.dragMoved || pointerMoved(state.lastPointer, point);
      renderer.panBy(point.x - state.lastPointer.x, point.y - state.lastPointer.y);
      state.lastPointer = point;
      return;
    }
    const node = renderer.getNodeAt(point);
    renderer.setHover(node?.node_id ?? null);
    canvas.style.cursor = node ? "pointer" : "grab";
  });
  canvas.addEventListener("pointerup", (event) => {
    const point = screenPoint(event);
    const clickedNode = renderer.getNodeAt(point);
    state.pointers.delete(event.pointerId);
    state.pinchDistance = 0;
    if (!state.dragMoved && clickedNode) {
      renderer.setSelected(clickedNode.node_id);
      updateDetails(clickedNode);
      if (clickedNode.status === "active" || clickedNode.status === "oversized") {
        post("selectPage", { id: clickedNode.node_id });
      }
    } else if (!state.dragMoved && !clickedNode) {
      renderer.setSelected(null);
      updateDetails(null);
    }
    state.draggingNode = null;
    state.panning = null;
    state.lastPointer = null;
    state.dragMoved = false;
    canvas.style.cursor = "grab";
  });
  canvas.addEventListener("pointercancel", (event) => {
    state.pointers.delete(event.pointerId);
    state.draggingNode = null;
    state.panning = null;
    state.lastPointer = null;
    state.dragMoved = false;
  });
  canvas.addEventListener("dblclick", (event) => {
    const node = renderer.getNodeAt(screenPoint(event));
    if (!node) return;
    state.pinned.delete(node.node_id);
    post("diagnostic", { message: `node unpinned: ${node.node_id}` });
    startLayout();
  });
  canvas.addEventListener("wheel", (event) => {
    event.preventDefault();
    const factor = Math.exp(-event.deltaY * 11e-4);
    renderer.zoomAt(screenPoint(event), factor);
  }, { passive: false });
  window.addEventListener("resize", () => renderer.resize());
  window.PocketWikiGraph = { receive };
  post("ready");
  setStatus("aguardando grafo");
})();

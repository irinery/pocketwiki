import {
  FilterConfig,
  FilteredSnapshot,
  GraphSnapshot,
  Point,
  PositionedNode,
  applyFilter,
  searchNodes
} from "./graph-core";
import { GraphRenderer } from "./renderer";

interface GraphPayload {
  command: "setGraph";
  graph: GraphSnapshot;
  filter: FilterConfig;
}

interface LayoutMessage {
  type: "layout";
  requestId: number;
  status: string;
  iteration: number;
  nodes: Array<{ id: string; x: number; y: number }>;
  message?: string;
}

const canvas = document.getElementById("graph") as HTMLCanvasElement | null;
const statusEl = document.getElementById("status");
const detailTitle = document.getElementById("detail-title");
const detailMeta = document.getElementById("detail-meta");
const detailLinks = document.getElementById("detail-links");

if (!canvas) {
  throw new Error("Canvas do grafo nao encontrado");
}

const renderer = new GraphRenderer(canvas);
const state = {
  graph: null as GraphSnapshot | null,
  filter: null as FilterConfig | null,
  filtered: null as FilteredSnapshot | null,
  worker: null as Worker | null,
  requestId: 0,
  draggingNode: null as PositionedNode | null,
  dragWasPinned: false,
  dragMoved: false,
  panning: null as { x: number; y: number } | null,
  lastPointer: null as Point | null,
  pinned: new Map<string, Point>(),
  pointers: new Map<number, Point>(),
  pinchDistance: 0,
  pendingCenterId: null as string | null
};

function post(type: string, payload: Record<string, unknown> = {}): void {
  try {
    window.webkit?.messageHandlers?.pocketwikiGraph?.postMessage({ type, ...payload });
  } catch {
    // WK bridge is absent when opened directly in a browser.
  }
}

function setStatus(text: string): void {
  if (statusEl) statusEl.textContent = text;
}

function receive(payload: GraphPayload): void {
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

function maybeQueueSearchCenter(graph: GraphSnapshot, filter: FilterConfig): void {
  const results = searchNodes(graph, filter.search_term || "");
  state.pendingCenterId = results.length === 1 ? results[0].node_id : null;
}

function startLayout(): void {
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
    worker.onmessage = (event: MessageEvent<LayoutMessage>) => handleLayoutMessage(event.data);
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

function handleLayoutMessage(message: LayoutMessage): void {
  if (message.requestId !== state.requestId) return;
  if (message.status === "error") {
    setStatus("layout com erro");
    post("diagnostic", { message: message.message || "erro no layout" });
    return;
  }

  renderer.updateLayout(message.nodes.map((node) => {
    return node;
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

function updateDetails(node: PositionedNode | null): void {
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

function screenPoint(event: MouseEvent | PointerEvent | WheelEvent): Point {
  const rect = canvas.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function pointerMoved(a: Point | null, b: Point): boolean {
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
    state.dragWasPinned = state.pinned.has(node.node_id);
    state.panning = null;
    renderer.beginNodeDrag(node.node_id);
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
    renderer.dragNodeTo(state.draggingNode.node_id, world);
    state.lastPointer = point;
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
  const draggedNode = state.draggingNode;
  state.pointers.delete(event.pointerId);
  state.pinchDistance = 0;

  if (draggedNode) {
    renderer.endNodeDrag(draggedNode.node_id, state.dragMoved);
    if (!state.dragMoved && !state.dragWasPinned) state.pinned.delete(draggedNode.node_id);
  }

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
  state.dragWasPinned = false;
  state.panning = null;
  state.lastPointer = null;
  state.dragMoved = false;
  canvas.style.cursor = "grab";
});

canvas.addEventListener("pointercancel", (event) => {
  state.pointers.delete(event.pointerId);
  if (state.draggingNode) renderer.endNodeDrag(state.draggingNode.node_id, state.dragMoved);
  state.draggingNode = null;
  state.dragWasPinned = false;
  state.panning = null;
  state.lastPointer = null;
  state.dragMoved = false;
});

canvas.addEventListener("dblclick", (event) => {
  const node = renderer.getNodeAt(screenPoint(event));
  if (!node) return;
  state.pinned.delete(node.node_id);
  renderer.unpinNode(node.node_id);
  post("diagnostic", { message: `node unpinned: ${node.node_id}` });
  startLayout();
});

canvas.addEventListener("wheel", (event) => {
  event.preventDefault();
  const factor = Math.exp(-event.deltaY * 0.0011);
  renderer.zoomAt(screenPoint(event), factor);
}, { passive: false });

window.addEventListener("resize", () => renderer.resize());

window.PocketWikiGraph = { receive };
post("ready");
setStatus("aguardando grafo");

declare global {
  interface Window {
    PocketWikiGraph?: {
      receive: (payload: GraphPayload) => void;
    };
    webkit?: {
      messageHandlers?: {
        pocketwikiGraph?: {
          postMessage: (message: unknown) => void;
        };
      };
    };
  }
}

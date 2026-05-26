import {
  FilteredSnapshot,
  GRAPH_COLORS,
  PositionedNode,
  Viewport,
  clamp,
  graphBounds,
  hitTest,
  nodeDegree,
  nodeRadius,
  screenToWorld,
  stableInitialPosition,
  worldToScreen
} from "./graph-core";

interface RenderEdge {
  source: RenderNode;
  target: RenderNode;
  type: string;
}

type RenderNode = PositionedNode & {
  targetX: number;
  targetY: number;
  vx: number;
  vy: number;
  inertiaFrames: number;
  pinned: boolean;
  dragging: boolean;
  lastImpulse: number;
  pinBeforeDrag: boolean;
};

const DRAG_INERTIA_FRAMES = 42;
const DRAG_DAMPING = 0.88;
const DRAG_MAX_SPEED = 18;
const LAYOUT_EASING = 0.22;

export class GraphRenderer {
  readonly canvas: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D;
  private nodes: RenderNode[] = [];
  private edges: RenderEdge[] = [];
  private nodeById = new Map<string, RenderNode>();
  private selectedId: string | null = null;
  private hoverId: string | null = null;
  private interactionFocusId: string | null = null;
  private interactionFrames = 0;
  private raf = 0;
  private viewport: Required<Viewport> = { x: 0, y: 0, zoom: 1, width: 1, height: 1 };
  private dpr = 1;

  constructor(canvas: HTMLCanvasElement) {
    this.canvas = canvas;
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) throw new Error("Canvas 2D indisponivel");
    this.ctx = ctx;
    this.resize();
  }

  setSnapshot(snapshot: FilteredSnapshot, selectedId: string | null): void {
    const previous = this.nodeById;
    this.selectedId = selectedId;
    this.hoverId = null;
    this.nodes = snapshot.nodes.map((node, index) => {
      const old = previous.get(node.node_id);
      const initial = old ?? stableInitialPosition(node, index, snapshot.nodes.length, selectedId);
      return {
        ...node,
        x: old?.x ?? initial.x,
        y: old?.y ?? initial.y,
        targetX: old?.targetX ?? initial.x,
        targetY: old?.targetY ?? initial.y,
        vx: old?.vx ?? 0,
        vy: old?.vy ?? 0,
        inertiaFrames: old?.inertiaFrames ?? 0,
        pinned: old?.pinned ?? false,
        dragging: old?.dragging ?? false,
        lastImpulse: old?.lastImpulse ?? 0,
        pinBeforeDrag: old?.pinBeforeDrag ?? false,
        radius: nodeRadius(node)
      };
    });
    this.nodeById = new Map(this.nodes.map((node) => [node.node_id, node]));
    this.edges = snapshot.edges
      .map((edge) => {
        const source = this.nodeById.get(edge.source);
        const target = this.nodeById.get(edge.target);
        return source && target ? { source, target, type: edge.type } : null;
      })
      .filter((edge): edge is RenderEdge => Boolean(edge));

    if (previous.size === 0 || snapshot.filter_config.scope === "local") {
      this.fitToGraph();
    }
    this.requestDraw();
  }

  updateLayout(layoutNodes: Array<{ id: string; x: number; y: number }>): void {
    for (const layoutNode of layoutNodes) {
      const node = this.nodeById.get(layoutNode.id);
      if (!node) continue;
      if (node.dragging || node.pinned || node.inertiaFrames > 0) continue;
      if (Number.isFinite(layoutNode.x) && Number.isFinite(layoutNode.y)) {
        node.targetX = layoutNode.x;
        node.targetY = layoutNode.y;
      }
    }
    this.requestDraw();
  }

  beginNodeDrag(id: string): void {
    const node = this.nodeById.get(id);
    if (!node) return;
    node.pinBeforeDrag = node.pinned;
    node.dragging = true;
    node.pinned = true;
    node.vx = 0;
    node.vy = 0;
    node.inertiaFrames = 0;
    node.targetX = node.x;
    node.targetY = node.y;
    this.interactionFocusId = id;
    this.interactionFrames = DRAG_INERTIA_FRAMES;
    this.requestDraw();
  }

  dragNodeTo(id: string, point: { x: number; y: number }): void {
    const node = this.nodeById.get(id);
    if (!node) return;
    const dx = point.x - node.x;
    const dy = point.y - node.y;
    node.x = point.x;
    node.y = point.y;
    node.targetX = point.x;
    node.targetY = point.y;
    node.vx = dx;
    node.vy = dy;
    node.lastImpulse = Math.hypot(dx, dy);
    this.injectDragImpulse(node, dx, dy);
    this.interactionFocusId = id;
    this.interactionFrames = DRAG_INERTIA_FRAMES;
    this.requestDraw();
  }

  endNodeDrag(id: string, keepPinned: boolean): void {
    const node = this.nodeById.get(id);
    if (!node) return;
    node.dragging = false;
    node.pinned = keepPinned || node.pinBeforeDrag;
    node.pinBeforeDrag = false;
    node.vx = 0;
    node.vy = 0;
    node.inertiaFrames = 0;
    node.targetX = node.x;
    node.targetY = node.y;
    this.interactionFocusId = id;
    this.interactionFrames = DRAG_INERTIA_FRAMES;
    this.requestDraw();
  }

  unpinNode(id: string): void {
    const node = this.nodeById.get(id);
    if (!node) return;
    node.dragging = false;
    node.pinned = false;
    node.pinBeforeDrag = false;
    node.inertiaFrames = 0;
    node.targetX = node.x;
    node.targetY = node.y;
    this.requestDraw();
  }

  resize(): void {
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

  fitToGraph(): void {
    const bounds = graphBounds(this.nodes);
    const width = Math.max(1, bounds.maxX - bounds.minX);
    const height = Math.max(1, bounds.maxY - bounds.minY);
    const zoomX = (this.viewport.width * 0.78) / width;
    const zoomY = (this.viewport.height * 0.78) / height;
    this.viewport.zoom = Math.min(1.08, Math.max(0.18, Math.min(zoomX, zoomY)));
    const cx = (bounds.minX + bounds.maxX) / 2;
    const cy = (bounds.minY + bounds.maxY) / 2;
    this.viewport.x = this.viewport.width / 2 - cx * this.viewport.zoom;
    this.viewport.y = this.viewport.height / 2 - cy * this.viewport.zoom;
    this.requestDraw();
  }

  centerOn(id: string): void {
    const node = this.nodeById.get(id);
    if (!node) return;
    this.viewport.x = this.viewport.width / 2 - node.x * this.viewport.zoom;
    this.viewport.y = this.viewport.height / 2 - node.y * this.viewport.zoom;
    this.requestDraw();
  }

  panBy(dx: number, dy: number): void {
    this.viewport.x += dx;
    this.viewport.y += dy;
    this.requestDraw();
  }

  zoomAt(screen: { x: number; y: number }, factor: number): void {
    const before = this.screenToWorld(screen);
    this.viewport.zoom = Math.max(0.12, Math.min(3.2, this.viewport.zoom * factor));
    this.viewport.x = screen.x - before.x * this.viewport.zoom;
    this.viewport.y = screen.y - before.y * this.viewport.zoom;
    this.requestDraw();
  }

  setHover(id: string | null): void {
    if (this.hoverId === id) return;
    this.hoverId = id;
    this.requestDraw();
  }

  setSelected(id: string | null): void {
    if (this.selectedId === id) return;
    this.selectedId = id;
    this.requestDraw();
  }

  getNodeAt(screen: { x: number; y: number }): PositionedNode | null {
    return hitTest(this.nodes, this.viewport, screen);
  }

  getNode(id: string | null): PositionedNode | null {
    return id ? this.nodeById.get(id) ?? null : null;
  }

  getNodes(): PositionedNode[] {
    return this.nodes;
  }

  screenToWorld(point: { x: number; y: number }): { x: number; y: number } {
    return screenToWorld(point, this.viewport);
  }

  requestDraw(): void {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      const moving = this.stepVisualPositions();
      this.draw();
      if (moving) this.requestDraw();
    });
  }

  private stepVisualPositions(): boolean {
    let moving = false;

    for (const node of this.nodes) {
      if (node.dragging || node.pinned) {
        node.vx *= 0.35;
        node.vy *= 0.35;
        continue;
      }

      if (node.inertiaFrames > 0) {
        node.vx = clamp(node.vx * DRAG_DAMPING, -DRAG_MAX_SPEED, DRAG_MAX_SPEED);
        node.vy = clamp(node.vy * DRAG_DAMPING, -DRAG_MAX_SPEED, DRAG_MAX_SPEED);
        node.x += node.vx;
        node.y += node.vy;
        node.inertiaFrames -= 1;
        if (node.inertiaFrames > 0 && (Math.abs(node.vx) > 0.03 || Math.abs(node.vy) > 0.03)) {
          moving = true;
        } else {
          node.vx = 0;
          node.vy = 0;
          node.inertiaFrames = 0;
          node.targetX = node.x;
          node.targetY = node.y;
        }
        continue;
      }

      const dx = node.targetX - node.x;
      const dy = node.targetY - node.y;
      if (Math.abs(dx) < 0.08 && Math.abs(dy) < 0.08) {
        node.x = node.targetX;
        node.y = node.targetY;
        continue;
      }
      node.x += dx * LAYOUT_EASING;
      node.y += dy * LAYOUT_EASING;
      moving = true;
    }

    if (this.interactionFrames > 0) {
      this.interactionFrames -= 1;
      if (this.interactionFrames > 0) {
        moving = true;
      } else {
        this.interactionFocusId = null;
      }
    }

    return moving;
  }

  private injectDragImpulse(source: RenderNode, dx: number, dy: number): void {
    if (Math.abs(dx) < 0.01 && Math.abs(dy) < 0.01) return;
    const connected = this.edges
      .map((edge) => edge.source === source ? edge.target : edge.target === source ? edge.source : null)
      .filter((node): node is RenderNode => Boolean(node) && !node.dragging && !node.pinned);
    const degreeScale = clamp(24 / Math.max(24, connected.length), 0.32, 1);
    const followFactor = clamp(0.58 * degreeScale, 0.24, 0.58);

    source.lastImpulse = Math.hypot(dx, dy);
    for (const target of connected) {
      target.vx = clamp(target.vx + dx * followFactor, -DRAG_MAX_SPEED, DRAG_MAX_SPEED);
      target.vy = clamp(target.vy + dy * followFactor, -DRAG_MAX_SPEED, DRAG_MAX_SPEED);
      target.inertiaFrames = DRAG_INERTIA_FRAMES;
    }
  }

  private draw(): void {
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

  private drawGrid(ctx: CanvasRenderingContext2D): void {
    const step = 64 * this.viewport.zoom;
    if (step < 22) return;
    const offsetX = ((this.viewport.x % step) + step) % step;
    const offsetY = ((this.viewport.y % step) + step) % step;
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

  private drawEdge(ctx: CanvasRenderingContext2D, edge: RenderEdge, activeIds: Set<string>): void {
    const source = worldToScreen(edge.source, this.viewport);
    const target = worldToScreen(edge.target, this.viewport);
    if (!this.segmentVisible(source, target, 80)) return;

    const focusId = this.interactionFocusId || this.hoverId || this.selectedId;
    const active = !focusId || edge.source.node_id === focusId || edge.target.node_id === focusId;
    ctx.globalAlpha = this.interactionFocusId ? (active ? 0.62 : 0.08) : (active ? 0.82 : 0.16);
    ctx.strokeStyle = active ? GRAPH_COLORS.edgeActive : GRAPH_COLORS.edge;
    ctx.lineWidth = active ? 0.9 : 0.45;
    if (edge.type === "missing") ctx.setLineDash([5, 7]);
    ctx.beginPath();
    ctx.moveTo(source.x, source.y);
    ctx.lineTo(target.x, target.y);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
  }

  private drawNode(ctx: CanvasRenderingContext2D, node: PositionedNode, activeIds: Set<string>): void {
    const point = worldToScreen(node, this.viewport);
    const radius = Math.max(2.6, node.radius * this.viewport.zoom);
    if (!this.pointVisible(point, radius + 24)) return;

    const selected = node.node_id === this.selectedId;
    const hovered = node.node_id === this.hoverId;
    const active = activeIds.size === 0 || activeIds.has(node.node_id);
    const color = selected || hovered ? GRAPH_COLORS.selectedNode : this.nodeColor(node);

    ctx.globalAlpha = active ? 1 : 0.28;
    const gradient = ctx.createRadialGradient(point.x - radius * 0.25, point.y - radius * 0.35, 1, point.x, point.y, radius);
    gradient.addColorStop(0, color);
    gradient.addColorStop(1, selected || hovered ? "rgba(149, 149, 149, 0.34)" : "rgba(47, 47, 47, 0.72)");
    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;

    ctx.strokeStyle = selected || hovered ? GRAPH_COLORS.selectedNode : "rgba(149, 149, 149, 0.32)";
    ctx.lineWidth = selected ? 2 : 0.85;
    if (!selected && !hovered && (node.status === "orphan_target" || node.status === "oversized")) ctx.setLineDash([3, 4]);
    ctx.beginPath();
    ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  private drawLabels(ctx: CanvasRenderingContext2D, activeIds: Set<string>): void {
    if (this.viewport.zoom < 0.3) return;

    const candidates = this.nodes
      .filter((node) => this.shouldLabel(node, activeIds))
      .sort((a, b) => {
        const selectedA = a.node_id === this.selectedId || a.node_id === this.hoverId ? 1 : 0;
        const selectedB = b.node_id === this.selectedId || b.node_id === this.hoverId ? 1 : 0;
        if (selectedA !== selectedB) return selectedB - selectedA;
        return nodeDegree(b) - nodeDegree(a);
      })
      .slice(0, this.viewport.zoom > 1.15 ? 110 : 60);

    const occupied: Array<{ x: number; y: number; width: number; height: number }> = [];
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

  private labelBox(
    ctx: CanvasRenderingContext2D,
    node: PositionedNode,
    point: { x: number; y: number },
    prominent: boolean
  ): { x: number; y: number; width: number; height: number } {
    const text = node.label.length > 44 ? `${node.label.slice(0, 41)}...` : node.label;
    const fontSize = prominent ? 12 : 10.5;
    ctx.font = `${prominent ? 700 : 500} ${fontSize}px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif`;
    const width = ctx.measureText(text).width;
    const x = point.x - width / 2;
    const y = point.y + node.radius * this.viewport.zoom + 12;
    return { x: x - 6, y: y - 3, width: width + 12, height: fontSize + 8 };
  }

  private drawLabel(
    ctx: CanvasRenderingContext2D,
    node: PositionedNode,
    point: { x: number; y: number },
    prominent: boolean,
    box: { x: number; y: number; width: number; height: number }
  ): void {
    const text = node.label.length > 44 ? `${node.label.slice(0, 41)}...` : node.label;
    const fontSize = prominent ? 12 : 10.5;
    const x = box.x + 6;
    const y = box.y + 3;
    ctx.font = `${prominent ? 700 : 500} ${fontSize}px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif`;

    if (prominent) {
      ctx.fillStyle = "rgba(8, 10, 13, 0.82)";
      roundRect(ctx, box.x, box.y, box.width, box.height, 7);
      ctx.fill();
      ctx.strokeStyle = "rgba(149, 149, 149, 0.48)";
      ctx.stroke();
    }

    ctx.fillStyle = prominent ? GRAPH_COLORS.text : GRAPH_COLORS.dim;
    ctx.fillText(text, x, y + fontSize);
  }

  private shouldLabel(node: PositionedNode, activeIds: Set<string>): boolean {
    if (node.node_id === this.selectedId || node.node_id === this.hoverId) return true;
    if (node.highlight === "search_result") return true;
    if (this.viewport.zoom > 0.5 && activeIds.has(node.node_id)) return true;
    if (this.viewport.zoom > 0.72 && nodeDegree(node) >= 10) return true;
    if (this.viewport.zoom > 1.18 && nodeDegree(node) >= 3) return true;
    return this.viewport.zoom > 1.65;
  }

  private activeIds(): Set<string> {
    const id = this.interactionFocusId || this.hoverId || this.selectedId;
    if (!id) return new Set();
    const ids = new Set<string>([id]);
    for (const edge of this.edges) {
      if (edge.source.node_id === id) ids.add(edge.target.node_id);
      if (edge.target.node_id === id) ids.add(edge.source.node_id);
    }
    return ids;
  }

  private nodeColor(node: PositionedNode): string {
    if (node.highlight === "selected") return GRAPH_COLORS.selectedNode;
    if (node.highlight === "search_result") return GRAPH_COLORS.searchNode;
    if (node.status === "oversized") return GRAPH_COLORS.oversizedNode;
    if (node.status === "orphan_target") return GRAPH_COLORS.isolatedNode;
    if (node.highlight === "neighbor") return GRAPH_COLORS.neighborNode;
    if (nodeDegree(node) === 0) return GRAPH_COLORS.isolatedNode;
    return GRAPH_COLORS.defaultNode;
  }

  private pointVisible(point: { x: number; y: number }, margin: number): boolean {
    return point.x >= -margin
      && point.y >= -margin
      && point.x <= this.viewport.width + margin
      && point.y <= this.viewport.height + margin;
  }

  private segmentVisible(a: { x: number; y: number }, b: { x: number; y: number }, margin: number): boolean {
    const minX = Math.min(a.x, b.x);
    const maxX = Math.max(a.x, b.x);
    const minY = Math.min(a.y, b.y);
    const maxY = Math.max(a.y, b.y);
    return maxX >= -margin
      && maxY >= -margin
      && minX <= this.viewport.width + margin
      && minY <= this.viewport.height + margin;
  }
}

function roundRect(context: CanvasRenderingContext2D, x: number, y: number, width: number, height: number, radius: number): void {
  context.beginPath();
  context.moveTo(x + radius, y);
  context.arcTo(x + width, y, x + width, y + height, radius);
  context.arcTo(x + width, y + height, x, y + height, radius);
  context.arcTo(x, y + height, x, y, radius);
  context.arcTo(x, y, x + width, y, radius);
  context.closePath();
}

function boxesOverlap(
  a: { x: number; y: number; width: number; height: number },
  b: { x: number; y: number; width: number; height: number }
): boolean {
  return a.x < b.x + b.width
    && a.x + a.width > b.x
    && a.y < b.y + b.height
    && a.y + a.height > b.y;
}

import test from "node:test";
import assert from "node:assert/strict";

const core = await import("../../Sources/PocketWikiMac/Resources/GraphView/graph-core.js");

function node(id, label = id, extra = {}) {
  return {
    node_id: id,
    label,
    path: `${id}.md`,
    folder: "",
    kind: "markdown",
    status: "active",
    health: "good",
    degree_in: 0,
    degree_out: 0,
    truncated: false,
    size_bytes: 10,
    incoming_ids: [],
    outgoing_ids: [],
    ...extra
  };
}

function edge(source, target) {
  return { source, target, label: "", type: "wiki" };
}

test("global filter keeps all nodes and edges", () => {
  const graph = {
    version: 1,
    selected_node_id: null,
    focus_node_id: null,
    truncated: false,
    nodes: [node("a"), node("b"), node("c"), node("d")],
    edges: [edge("a", "b"), edge("b", "c"), edge("c", "d")]
  };

  const filtered = core.applyFilter(graph, { scope: "global", depth: 1, selected_node_id: null, search_term: "" }, 500);
  assert.equal(filtered.nodes.length, 4);
  assert.equal(filtered.edges.length, 3);
});

test("local filter uses bidirectional BFS depth", () => {
  const graph = {
    version: 1,
    selected_node_id: "b",
    focus_node_id: "b",
    truncated: false,
    nodes: [node("a"), node("b"), node("c"), node("d")],
    edges: [edge("a", "b"), edge("b", "c"), edge("c", "d")]
  };

  const depth1 = core.applyFilter(graph, { scope: "local", depth: 1, selected_node_id: "b", search_term: "" }, 500);
  assert.deepEqual(new Set(depth1.nodes.map((item) => item.node_id)), new Set(["a", "b", "c"]));
  assert.equal(depth1.edges.length, 2);

  const depth2 = core.applyFilter(graph, { scope: "local", depth: 2, selected_node_id: "b", search_term: "" }, 500);
  assert.deepEqual(new Set(depth2.nodes.map((item) => item.node_id)), new Set(["a", "b", "c", "d"]));
  assert.equal(depth2.edges.length, 3);
});

test("local filter falls back to global without selection and handles cycles", () => {
  const graph = {
    version: 1,
    selected_node_id: null,
    focus_node_id: null,
    truncated: false,
    nodes: [node("a"), node("b"), node("c")],
    edges: [edge("a", "b"), edge("b", "c"), edge("c", "a")]
  };

  const fallback = core.applyFilter(graph, { scope: "local", depth: 1, selected_node_id: null, search_term: "" }, 500);
  assert.equal(fallback.nodes.length, 3);

  const cycle = core.applyFilter(graph, { scope: "local", depth: 1, selected_node_id: "a", search_term: "" }, 500);
  assert.deepEqual(new Set(cycle.nodes.map((item) => item.node_id)), new Set(["a", "b", "c"]));
});

test("search is case-insensitive and truncates long terms", () => {
  const graph = {
    version: 1,
    selected_node_id: null,
    focus_node_id: null,
    truncated: false,
    nodes: [node("rene", "Rene Descartes"), node("desc", "Descricao"), node("fisica", "Fisica")],
    edges: []
  };

  assert.deepEqual(core.searchNodes(graph, "DESC").map((item) => item.node_id), ["rene", "desc"]);
  const filter = core.normalizeFilter({ scope: "global", depth: 99, selected_node_id: null, search_term: "x".repeat(10_001) });
  assert.equal(filter.depth, 10);
  assert.equal(filter.search_term.length, 200);
});

test("world/screen transforms roundtrip", () => {
  const viewport = { x: 320, y: 180, zoom: 1.7 };
  const world = { x: -42, y: 88 };
  const screen = core.worldToScreen(world, viewport);
  const roundtrip = core.screenToWorld(screen, viewport);
  assert.ok(Math.abs(roundtrip.x - world.x) < 0.000001);
  assert.ok(Math.abs(roundtrip.y - world.y) < 0.000001);
});

test("hit test prioritizes higher incoming degree", () => {
  const viewport = { x: 0, y: 0, zoom: 1 };
  const low = { ...node("low", "Low", { degree_in: 1, degree_out: 1 }), highlight: "default", visible: true, x: 10, y: 10, radius: 12 };
  const high = { ...node("high", "High", { degree_in: 9, degree_out: 0 }), highlight: "default", visible: true, x: 12, y: 10, radius: 12 };
  const hit = core.hitTest([low, high], viewport, { x: 11, y: 10 });
  assert.equal(hit.node_id, "high");
});

test("initial layout is deterministic and finite", () => {
  const a = core.stableInitialPosition(node("a", "A", { folder: "infra", degree_in: 10 }), 1, 180, null);
  const b = core.stableInitialPosition(node("a", "A", { folder: "infra", degree_in: 10 }), 1, 180, null);
  assert.deepEqual(a, b);
  assert.ok(Number.isFinite(a.x));
  assert.ok(Number.isFinite(a.y));
});

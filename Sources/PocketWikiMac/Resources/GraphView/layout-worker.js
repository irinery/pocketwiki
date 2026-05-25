// src/graph-view/graph-core.ts
var GRAPH_LIMITS = {
  maxVisibleNodes: 500,
  maxGlobalNodes: 5e3,
  maxDepth: 10,
  maxSearchChars: 200,
  worldMin: -5e3,
  worldMax: 5e3
};
function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
function hashString(value) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
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

// src/graph-view/layout-worker.ts
var token = 0;
self.onmessage = (event) => {
  if (event.data.type === "cancel") {
    token += 1;
    return;
  }
  const currentToken = token + 1;
  token = currentToken;
  runLayout(event.data, currentToken);
};
function runLayout(message, currentToken) {
  try {
    const nodes = makeNodes(message);
    const edges = makeEdges(nodes, message.edges);
    const startedAt = performance.now();
    let iteration = 0;
    let alpha = 1;
    publish(message.requestId, "running", iteration, nodes);
    const stepBatch = () => {
      if (currentToken !== token) {
        publish(message.requestId, "cancelled", iteration, nodes);
        return;
      }
      for (let index = 0; index < 5 && iteration < 720; index += 1) {
        tick(nodes, edges, alpha);
        alpha *= 0.988;
        iteration += 1;
      }
      const elapsed = performance.now() - startedAt;
      const timedOut = elapsed > 1e4;
      const converged = alpha < 0.01 || averageVelocity(nodes) < 0.012;
      const done = converged || timedOut || iteration >= 720;
      publish(message.requestId, done ? timedOut ? "timeout" : "converged" : "running", iteration, nodes);
      if (!done) {
        setTimeout(stepBatch, 0);
      }
    };
    setTimeout(stepBatch, 0);
  } catch (error) {
    self.postMessage({
      type: "layout",
      requestId: message.requestId,
      status: "error",
      iteration: 0,
      nodes: [],
      message: error instanceof Error ? error.message : String(error)
    });
  }
}
function makeNodes(message) {
  const total = Math.max(1, message.nodes.length);
  return message.nodes.map((node, index) => {
    const pinned = message.pinned[node.id];
    const initial = pinned ?? stableInitialPosition(
      {
        node_id: node.id,
        folder: node.folder,
        degree_in: node.degree_in,
        degree_out: node.degree_out
      },
      index,
      total,
      message.selectedId
    );
    const jitter = (hashString(`${node.id}:${index}`) % 1e3 / 1e3 - 0.5) * 8;
    return {
      ...node,
      x: clamp(initial.x + jitter, GRAPH_LIMITS.worldMin, GRAPH_LIMITS.worldMax),
      y: clamp(initial.y - jitter, GRAPH_LIMITS.worldMin, GRAPH_LIMITS.worldMax),
      vx: 0,
      vy: 0,
      radius: nodeRadius({ ...node, node_id: node.id }),
      pinned: Boolean(pinned)
    };
  });
}
function makeEdges(nodes, inputEdges) {
  const byId = new Map(nodes.map((node) => [node.id, node]));
  return inputEdges.map((edge) => {
    const source = byId.get(edge.source);
    const target = byId.get(edge.target);
    return source && target ? { source, target } : null;
  }).filter((edge) => Boolean(edge));
}
function tick(nodes, edges, alpha) {
  const quad = buildQuad(nodes);
  const charge = clamp(2300 + nodes.length * 9, 2300, 6800);
  const ideal = clamp(165 + nodes.length * 0.28, 165, 340);
  for (const node of nodes) {
    applyRepulsion(node, quad, charge, alpha);
  }
  for (const edge of edges) {
    const source = edge.source;
    const target = edge.target;
    const dx = target.x - source.x;
    const dy = target.y - source.y;
    const distance = Math.max(0.1, Math.sqrt(dx * dx + dy * dy));
    const desired = ideal + (source.radius + target.radius) * 2.8;
    const force = (distance - desired) * 0.014 * alpha;
    const fx = dx / distance * force;
    const fy = dy / distance * force;
    if (!source.pinned) {
      source.vx += fx;
      source.vy += fy;
    }
    if (!target.pinned) {
      target.vx -= fx;
      target.vy -= fy;
    }
  }
  applySpatialCollision(nodes, alpha);
  for (const node of nodes) {
    const degree = nodeDegree({ degree_in: node.degree_in, degree_out: node.degree_out });
    const gravity = node.highlight === "selected" ? 0.03 : degree >= 12 ? 9e-3 : 38e-4;
    if (!node.pinned) {
      node.vx -= node.x * gravity * alpha;
      node.vy -= node.y * gravity * alpha;
      node.vx *= 0.86;
      node.vy *= 0.86;
      node.x = clamp(node.x + clamp(node.vx, -18, 18), GRAPH_LIMITS.worldMin, GRAPH_LIMITS.worldMax);
      node.y = clamp(node.y + clamp(node.vy, -18, 18), GRAPH_LIMITS.worldMin, GRAPH_LIMITS.worldMax);
    }
  }
}
function applyRepulsion(node, quad, charge, alpha) {
  if (quad.mass === 0) return;
  if (!quad.children && quad.node === node) return;
  const dx = node.x - quad.cx;
  const dy = node.y - quad.cy;
  const distanceSq = Math.max(36, dx * dx + dy * dy);
  const distance = Math.sqrt(distanceSq);
  const theta = 0.82;
  if (!quad.children || quad.size / distance < theta) {
    const force = charge * quad.mass * alpha / distanceSq;
    if (!node.pinned) {
      node.vx += dx / distance * force;
      node.vy += dy / distance * force;
    }
    return;
  }
  for (const child of quad.children) {
    applyRepulsion(node, child, charge, alpha);
  }
}
function applySpatialCollision(nodes, alpha) {
  const cellSize = 52;
  const cells = /* @__PURE__ */ new Map();
  for (const node of nodes) {
    const cx = Math.floor(node.x / cellSize);
    const cy = Math.floor(node.y / cellSize);
    const key = `${cx}:${cy}`;
    const bucket = cells.get(key);
    if (bucket) bucket.push(node);
    else cells.set(key, [node]);
  }
  for (const node of nodes) {
    const cx = Math.floor(node.x / cellSize);
    const cy = Math.floor(node.y / cellSize);
    for (let ox = -1; ox <= 1; ox += 1) {
      for (let oy = -1; oy <= 1; oy += 1) {
        const bucket = cells.get(`${cx + ox}:${cy + oy}`);
        if (!bucket) continue;
        for (const other of bucket) {
          if (other === node) continue;
          const dx = node.x - other.x;
          const dy = node.y - other.y;
          const distance = Math.max(0.1, Math.sqrt(dx * dx + dy * dy));
          const minimum = node.radius + other.radius + 30;
          if (distance >= minimum) continue;
          const force = (minimum - distance) / minimum * 3.2 * alpha;
          if (!node.pinned) {
            node.vx += dx / distance * force;
            node.vy += dy / distance * force;
          }
        }
      }
    }
  }
}
function buildQuad(nodes) {
  let minX = -100;
  let minY = -100;
  let maxX = 100;
  let maxY = 100;
  for (const node of nodes) {
    minX = Math.min(minX, node.x);
    minY = Math.min(minY, node.y);
    maxX = Math.max(maxX, node.x);
    maxY = Math.max(maxY, node.y);
  }
  const size = Math.max(maxX - minX, maxY - minY, 1) + 64;
  const root = makeQuad((minX + maxX) / 2, (minY + maxY) / 2, size);
  for (const node of nodes) {
    insert(root, node);
  }
  accumulate(root);
  return root;
}
function makeQuad(x, y, size) {
  return { x, y, size, mass: 0, cx: x, cy: y, node: null, children: null };
}
function insert(quad, node) {
  if (!quad.children && !quad.node) {
    quad.node = node;
    return;
  }
  if (!quad.children) {
    subdivide(quad);
    if (quad.node) {
      insertIntoChild(quad, quad.node);
      quad.node = null;
    }
  }
  insertIntoChild(quad, node);
}
function subdivide(quad) {
  const childSize = quad.size / 2;
  const offset = childSize / 2;
  quad.children = [
    makeQuad(quad.x - offset, quad.y - offset, childSize),
    makeQuad(quad.x + offset, quad.y - offset, childSize),
    makeQuad(quad.x - offset, quad.y + offset, childSize),
    makeQuad(quad.x + offset, quad.y + offset, childSize)
  ];
}
function insertIntoChild(quad, node) {
  const right = node.x >= quad.x ? 1 : 0;
  const bottom = node.y >= quad.y ? 2 : 0;
  insert(quad.children[right + bottom], node);
}
function accumulate(quad) {
  if (!quad.children) {
    if (quad.node) {
      quad.mass = 1;
      quad.cx = quad.node.x;
      quad.cy = quad.node.y;
    }
    return;
  }
  let mass = 0;
  let cx = 0;
  let cy = 0;
  for (const child of quad.children) {
    accumulate(child);
    mass += child.mass;
    cx += child.cx * child.mass;
    cy += child.cy * child.mass;
  }
  quad.mass = mass;
  quad.cx = mass > 0 ? cx / mass : quad.x;
  quad.cy = mass > 0 ? cy / mass : quad.y;
}
function averageVelocity(nodes) {
  if (nodes.length === 0) return 0;
  let total = 0;
  for (const node of nodes) {
    total += Math.abs(node.vx) + Math.abs(node.vy);
  }
  return total / nodes.length;
}
function publish(requestId, status, iteration, nodes) {
  self.postMessage({
    type: "layout",
    requestId,
    status,
    iteration,
    nodes: nodes.map((node) => ({ id: node.id, x: node.x, y: node.y }))
  });
}

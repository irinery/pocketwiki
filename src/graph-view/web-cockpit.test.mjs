import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const html = readFileSync(new URL("../../wiki-cockpit.html", import.meta.url), "utf8");
const graphCore = readFileSync(new URL("./graph-core.ts", import.meta.url), "utf8");
const renderer = readFileSync(new URL("./renderer.ts", import.meta.url), "utf8");
const main = readFileSync(new URL("./main.ts", import.meta.url), "utf8");
const cockpitGraphScript = html.slice(html.indexOf("// Graph"), html.indexOf("function randomPage"));

test("web cockpit graph script remains parseable", () => {
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]);
  assert.ok(scripts.length > 0);
  for (const script of scripts) {
    assert.doesNotThrow(() => new Function(script));
  }
});

test("web cockpit uses the live map controls and worker renderer", () => {
  assert.match(html, /id="graph-global-btn"/);
  assert.match(html, /id="graph-local-btn"/);
  assert.match(html, /id="graph-depth"/);
  assert.match(html, /id="graph-search"/);
  assert.match(html, /id="graph-detail"/);
  assert.match(html, /function graphWorkerUrl\(\)/);
  assert.match(html, /new Worker\(graphWorkerUrl\(\)\)/);
});

test("web cockpit declares pinned map and local drag physics", () => {
  assert.match(cockpitGraphScript, /let graphPinned = new Map\(\);/);
  assert.match(cockpitGraphScript, /function graphBeginNodeDrag\(node\)/);
  assert.match(cockpitGraphScript, /function graphDragNodeTo\(node, point\)/);
  assert.match(cockpitGraphScript, /function graphEndNodeDrag\(node, keepPinned\)/);
  assert.match(cockpitGraphScript, /function graphInjectDragImpulse\(source, dx, dy\)/);
  assert.match(cockpitGraphScript, /GRAPH_DRAG_INERTIA_FRAMES = 42/);
  assert.match(cockpitGraphScript, /inertiaFrames/);
  assert.match(cockpitGraphScript, /followFactor = graphClamp\(\.58 \* degreeScale, \.24, \.58\)/);
});

test("graph renderers expose interactive drag APIs", () => {
  for (const symbol of ["beginNodeDrag", "dragNodeTo", "endNodeDrag", "unpinNode"]) {
    assert.match(renderer, new RegExp(`${symbol}\\(`));
  }
  assert.match(main, /renderer\.beginNodeDrag/);
  assert.match(main, /renderer\.dragNodeTo/);
  assert.match(main, /renderer\.endNodeDrag/);
  assert.match(main, /renderer\.unpinNode/);
});

test("graph renderers do not use global edge springs or external halos", () => {
  for (const source of [renderer, cockpitGraphScript]) {
    assert.equal(source.includes("desired = 128"), false);
    assert.equal(source.includes("graphApplyVelocity(source, fx, fy)"), false);
    assert.equal(source.includes("applyVelocity(edge.source"), false);
    assert.equal(source.includes("radius + (selected ? 12 : 8)"), false);
  }
  assert.match(renderer, /DRAG_INERTIA_FRAMES = 42/);
  assert.match(renderer, /inertiaFrames/);
  assert.match(renderer, /followFactor = clamp\(0\.58 \* degreeScale, 0\.24, 0\.58\)/);
});

test("graph palette is grayscale-only in both renderers", () => {
  assert.match(graphCore, /defaultNode: "#2F2F2F"/);
  assert.match(graphCore, /selectedNode: "#959595"/);
  assert.match(cockpitGraphScript, /return '#2F2F2F';/);
  assert.match(cockpitGraphScript, /return '#959595';/);
  assert.match(cockpitGraphScript, /rgba\(47,47,47,\.55\)/);
  assert.match(cockpitGraphScript, /rgba\(149,149,149,\.75\)/);

  const legacyGraphColors = [
    "#4ade80",
    "#f0c36a",
    "#72d6ff",
    "#ff8080",
    "#7bd88f",
    "#86efac",
    "rgba(134,239,172",
    "rgba(74,222,128",
    "rgba(255,128,128"
  ];

  for (const token of legacyGraphColors) {
    assert.equal(graphCore.includes(token), false, `${token} should not remain in graph-core`);
    assert.equal(renderer.includes(token), false, `${token} should not remain in renderer`);
    assert.equal(cockpitGraphScript.includes(token), false, `${token} should not remain in cockpit graph`);
  }
});

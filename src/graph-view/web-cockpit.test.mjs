import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const html = readFileSync(new URL("../../wiki-cockpit.html", import.meta.url), "utf8");

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

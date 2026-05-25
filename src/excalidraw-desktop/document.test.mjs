import assert from "node:assert/strict";
import {
  createBlankExcalidrawScene,
  parseExcalidrawDocument,
  serializeExcalidrawDocument,
  serializePlainExcalidraw,
} from "./src/document.js";
import LZString from "lz-string";

const scene = {
  type: "excalidraw",
  version: 2,
  elements: [{ id: "a", type: "text", rawText: "Servidor", x: 1, y: 2 }],
  appState: { name: "Mapa" },
  files: {},
};

{
  const parsed = parseExcalidrawDocument({
    path: "Mapa.excalidraw",
    content: JSON.stringify(scene),
  });
  assert.equal(parsed.editable, true);
  assert.equal(parsed.format, "json");
  assert.equal(parsed.scene.elements[0].rawText, "Servidor");
  assert.match(serializePlainExcalidraw(parsed.scene), /"type": "excalidraw"/);
}

{
  const markdown = `# Mapa\n\n## Drawing\n\n\`\`\`json\n${JSON.stringify(scene)}\n\`\`\`\n`;
  const parsed = parseExcalidrawDocument({ path: "Mapa.excalidraw.md", content: markdown });
  const next = serializeExcalidrawDocument({
    path: "Mapa.excalidraw.md",
    originalContent: markdown,
    format: parsed.format,
    fence: parsed.fence,
    scene: { ...parsed.scene, elements: [] },
  });
  assert.match(next, /```json/);
  assert.match(next, /"elements": \[\]/);
}

{
  const compressed = LZString.compressToBase64(JSON.stringify(scene));
  const markdown = `# Mapa\n\n## Drawing\n\n\`\`\`compressed-json\n${compressed}\n\`\`\`\n`;
  const parsed = parseExcalidrawDocument({ path: "Mapa.excalidraw.md", content: markdown });
  assert.equal(parsed.format, "markdown-compressed-json");
  assert.equal(parsed.scene.elements[0].rawText, "Servidor");
  const next = serializeExcalidrawDocument({
    path: "Mapa.excalidraw.md",
    originalContent: markdown,
    format: parsed.format,
    fence: parsed.fence,
    scene: { ...parsed.scene, elements: [] },
  });
  assert.match(next, /```compressed-json/);
  const reparsed = parseExcalidrawDocument({ path: "Mapa.excalidraw.md", content: next });
  assert.equal(reparsed.scene.elements.length, 0);
}

{
  const parsed = parseExcalidrawDocument({
    path: "Notas.excalidraw.md",
    content: "# Sem desenho\n\nTexto solto",
  });
  assert.equal(parsed.editable, false);
  assert.match(parsed.error, /sem cena/i);
}

{
  const blank = createBlankExcalidrawScene("Novo");
  assert.equal(blank.type, "excalidraw");
  assert.deepEqual(blank.elements, []);
}

console.log("ok - excalidraw desktop document middleware");


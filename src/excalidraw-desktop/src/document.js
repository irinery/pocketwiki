import LZString from "lz-string";

const DEFAULT_SCENE_SOURCE = "https://github.com/irinery/PocketWiki";

export function createBlankExcalidrawScene(name = "Novo desenho") {
  return {
    type: "excalidraw",
    version: 2,
    source: DEFAULT_SCENE_SOURCE,
    elements: [],
    appState: {
      name,
      theme: "dark",
      viewBackgroundColor: "#ffffff",
    },
    files: {},
  };
}

export function parseExcalidrawDocument({ path = "", content = "", title = "" } = {}) {
  const clean = String(content || "").trim();
  const lowerPath = String(path || "").toLowerCase();

  const direct = tryParseScene(clean);
  if (direct) {
    return {
      scene: normalizeScene(direct, title || baseName(path)),
      format: lowerPath.endsWith(".excalidraw.md") ? "markdown-json-object" : "json",
      editable: true,
    };
  }

  const compressed = findFence(content, "compressed-json");
  if (compressed) {
    const inflated = LZString.decompressFromBase64(compressed.body.replace(/\s+/g, ""));
    const scene = tryParseScene(inflated || "");
    if (scene) {
      return {
        scene: normalizeScene(scene, title || baseName(path)),
        format: "markdown-compressed-json",
        editable: true,
        fence: compressed,
      };
    }
  }

  const jsonFence = findFence(content, "json") || findFence(content, "excalidraw");
  if (jsonFence) {
    const scene = tryParseScene(jsonFence.body);
    if (scene) {
      return {
        scene: normalizeScene(scene, title || baseName(path)),
        format: "markdown-json",
        editable: true,
        fence: jsonFence,
      };
    }
  }

  const embedded = extractEmbeddedScene(content);
  if (embedded) {
    return {
      scene: normalizeScene(embedded.scene, title || baseName(path)),
      format: "markdown-json-object",
      editable: true,
      range: embedded.range,
    };
  }

  return {
    scene: null,
    format: "unsupported",
    editable: false,
    error: "Arquivo sem cena Excalidraw JSON editavel.",
  };
}

export function serializeExcalidrawDocument({
  path = "",
  originalContent = "",
  format = "json",
  scene,
  fence,
  range,
} = {}) {
  if (!scene || !Array.isArray(scene.elements)) {
    throw new Error("Cena Excalidraw invalida para salvar.");
  }

  const json = stableSceneJSON(scene);
  if (format === "json" || String(path).toLowerCase().endsWith(".excalidraw")) {
    return json;
  }

  if (format === "markdown-compressed-json" && fence) {
    return replaceRange(
      originalContent,
      fence.bodyStart,
      fence.bodyEnd,
      `\n${LZString.compressToBase64(json)}\n`,
    );
  }

  if (format === "markdown-json" && fence) {
    return replaceRange(originalContent, fence.bodyStart, fence.bodyEnd, `\n${json}\n`);
  }

  if (format === "markdown-json-object" && range) {
    return replaceRange(originalContent, range.start, range.end, json);
  }

  return json;
}

export function serializePlainExcalidraw(scene) {
  return stableSceneJSON(scene);
}

function normalizeScene(scene, fallbackName) {
  const source = scene && typeof scene === "object" ? scene : {};
  return {
    type: source.type || "excalidraw",
    version: source.version || 2,
    source: source.source || DEFAULT_SCENE_SOURCE,
    elements: Array.isArray(source.elements) ? source.elements : [],
    appState: {
      ...(source.appState && typeof source.appState === "object" ? source.appState : {}),
      name: source.appState?.name || fallbackName || "Desenho",
    },
    files: source.files && typeof source.files === "object" ? source.files : {},
  };
}

function stableSceneJSON(scene) {
  const normalized = normalizeScene(scene, scene?.appState?.name);
  return `${JSON.stringify(normalized, null, 2)}\n`;
}

function tryParseScene(raw) {
  const text = String(raw || "").trim();
  if (!text) return null;
  try {
    const parsed = JSON.parse(text);
    return parsed && Array.isArray(parsed.elements) ? parsed : null;
  } catch {
    const end = text.lastIndexOf("}");
    if (end < 1) return null;
    try {
      const parsed = JSON.parse(text.slice(0, end + 1));
      return parsed && Array.isArray(parsed.elements) ? parsed : null;
    } catch {
      return null;
    }
  }
}

function findFence(content, language) {
  const text = String(content || "");
  const pattern = new RegExp("```" + language + "\\s*\\n([\\s\\S]*?)```", "i");
  const match = pattern.exec(text);
  if (!match) return null;
  return {
    language,
    body: match[1],
    bodyStart: match.index + match[0].indexOf(match[1]),
    bodyEnd: match.index + match[0].indexOf(match[1]) + match[1].length,
  };
}

function extractEmbeddedScene(content) {
  const text = String(content || "");
  const starts = [];
  for (const pattern of [/"type"\s*:\s*"excalidraw"/gi, /"elements"\s*:\s*\[/gi]) {
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const start = text.lastIndexOf("{", match.index);
      if (start >= 0) starts.push(start);
    }
  }

  for (const start of [...new Set(starts)].sort((a, b) => a - b)) {
    const end = balancedObjectEnd(text, start);
    if (end <= start) continue;
    const candidate = text.slice(start, end);
    const scene = tryParseScene(candidate);
    if (scene) return { scene, range: { start, end } };
  }
  return null;
}

function balancedObjectEnd(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === "\"") inString = false;
      continue;
    }
    if (char === "\"") inString = true;
    else if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return index + 1;
    }
  }
  return -1;
}

function replaceRange(value, start, end, replacement) {
  return `${value.slice(0, start)}${replacement}${value.slice(end)}`;
}

function baseName(path) {
  return String(path || "")
    .split("/")
    .pop()
    .replace(/\.excalidraw(?:\.md)?$/i, "")
    .replace(/\.md$/i, "") || "Desenho";
}


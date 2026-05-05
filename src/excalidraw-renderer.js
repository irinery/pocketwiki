import { exportToSvg } from "@excalidraw/utils";

const DEFAULT_APP_STATE = {
  exportBackground: false,
  exportEmbedScene: false,
  exportScale: 1,
  exportWithDarkMode: true,
  frameRendering: {
    enabled: true,
    name: true,
    outline: true,
    clip: true,
  },
  theme: "dark",
  viewBackgroundColor: "transparent",
};

function normalizeScene(scene, options = {}) {
  const source = scene && typeof scene === "object" ? scene : {};
  const elements = Array.isArray(source.elements) ? source.elements.filter((el) => el && !el.isDeleted) : [];
  const files = source.files && typeof source.files === "object" ? source.files : {};
  const appState = {
    ...DEFAULT_APP_STATE,
    ...(source.appState && typeof source.appState === "object" ? source.appState : {}),
    exportBackground: false,
    exportEmbedScene: false,
    exportPadding: options.padding ?? 48,
    exportScale: options.scale ?? 1,
    exportWithDarkMode: options.theme !== "light",
    theme: options.theme === "light" ? "light" : "dark",
    viewBackgroundColor: options.backgroundColor || DEFAULT_APP_STATE.viewBackgroundColor,
  };

  return { elements, appState, files };
}

async function exportOfficialSvg(scene, options = {}) {
  const restored = normalizeScene(scene, options);
  const elements = restored.elements.filter((el) => el && !el.isDeleted);
  const appState = {
    ...restored.appState,
    exportBackground: false,
    exportEmbedScene: false,
    exportPadding: options.padding ?? 48,
    exportScale: options.scale ?? 1,
    exportWithDarkMode: options.theme !== "light",
    viewBackgroundColor: options.backgroundColor || DEFAULT_APP_STATE.viewBackgroundColor,
  };
  const files = restored.files || {};

  const svg = await exportToSvg({
    elements,
    appState,
    files,
    exportPadding: appState.exportPadding,
    reuseImages: true,
    skipInliningFonts: true,
  });

  svg.setAttribute("role", "img");
  if (options.title) svg.setAttribute("aria-label", options.title);
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
  svg.style.width = "100%";
  svg.style.height = "100%";
  return svg.outerHTML;
}

export async function renderExcalidrawToSvg(scene, options = {}) {
  return exportOfficialSvg(scene, options);
}

window.PocketExcalidrawRenderer = {
  renderExcalidrawToSvg,
};

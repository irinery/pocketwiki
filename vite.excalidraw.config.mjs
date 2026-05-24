import { defineConfig } from "vite";

export default defineConfig({
  root: "src/excalidraw-desktop",
  base: "./",
  build: {
    outDir: "../../Sources/PocketWikiMac/Resources/ExcalidrawEditor",
    emptyOutDir: true,
    assetsDir: "assets",
  },
});


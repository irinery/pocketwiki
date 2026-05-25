import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  MainMenu,
  WelcomeScreen,
  serializeAsJSON,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./style.css";
import {
  createBlankExcalidrawScene,
  parseExcalidrawDocument,
  serializeExcalidrawDocument,
  serializePlainExcalidraw,
} from "./document.js";

const AUTOSAVE_DELAY_MS = 4500;

function post(type, payload = {}) {
  const message = { type, ...payload };
  if (window.webkit?.messageHandlers?.pocketwikiExcalidraw) {
    window.webkit.messageHandlers.pocketwikiExcalidraw.postMessage(message);
  } else {
    console.debug("[PocketWiki Excalidraw]", message);
  }
}

function PocketExcalidrawApp() {
  const [documentState, setDocumentState] = useState(null);
  const [readonly, setReadonly] = useState(true);
  const [error, setError] = useState("");
  const [isDirty, setIsDirty] = useState(false);
  const [loadKey, setLoadKey] = useState("empty");
  const apiRef = useRef(null);
  const currentDocumentRef = useRef(null);
  const loadingRef = useRef(false);
  const dirtyRef = useRef(false);
  const autosaveTimerRef = useRef(null);

  const clearAutosave = useCallback(() => {
    if (autosaveTimerRef.current) {
      window.clearTimeout(autosaveTimerRef.current);
      autosaveTimerRef.current = null;
    }
  }, []);

  const markDirty = useCallback((dirty) => {
    dirtyRef.current = dirty;
    setIsDirty(dirty);
    post("dirtyChanged", {
      dirty,
      id: currentDocumentRef.current?.id || "",
      path: currentDocumentRef.current?.path || "",
    });
  }, []);

  const currentScene = useCallback(() => {
    const api = apiRef.current;
    if (!api) return documentState?.scene || createBlankExcalidrawScene();
    const json = serializeAsJSON(
      api.getSceneElementsIncludingDeleted(),
      api.getAppState(),
      api.getFiles(),
      "local",
    );
    return JSON.parse(json);
  }, [documentState]);

  const sendSave = useCallback((type, mode = "document", reason = "manual") => {
    const doc = currentDocumentRef.current;
    if (!doc && mode !== "export") return;

    try {
      const scene = currentScene();
      const content = mode === "export"
        ? serializePlainExcalidraw(scene)
        : serializeExcalidrawDocument({
            path: doc.path,
            originalContent: doc.originalContent,
            format: doc.format,
            fence: doc.fence,
            range: doc.range,
            scene,
          });

      post(type, {
        id: doc?.id || "",
        path: doc?.path || "",
        title: doc?.title || scene.appState?.name || "Desenho",
        content,
        saveMode: mode,
        reason,
      });

      if (mode === "document") {
        clearAutosave();
        currentDocumentRef.current = { ...doc, originalContent: content };
        markDirty(false);
      }
    } catch (err) {
      const message = err?.message || "Falha ao serializar desenho.";
      setError(message);
      post("error", { message });
    }
  }, [clearAutosave, currentScene, markDirty]);

  const loadDocument = useCallback((payload) => {
    clearAutosave();
    loadingRef.current = true;
    setError("");
    setReadonly(Boolean(payload.readonly));

    const parsed = parseExcalidrawDocument(payload);
    if (!parsed.editable || !parsed.scene) {
      const message = parsed.error || "Arquivo sem cena editavel.";
      setError(message);
      post("error", { id: payload.id || "", path: payload.path || "", message });
      setDocumentState(null);
      currentDocumentRef.current = null;
      loadingRef.current = false;
      markDirty(false);
      return;
    }

    currentDocumentRef.current = {
      id: payload.id || payload.path || "document",
      path: payload.path || "",
      title: payload.title || parsed.scene.appState?.name || "Desenho",
      originalContent: payload.content || "",
      format: parsed.format,
      fence: parsed.fence,
      range: parsed.range,
    };
    setDocumentState({
      id: currentDocumentRef.current.id,
      title: currentDocumentRef.current.title,
      path: currentDocumentRef.current.path,
      scene: parsed.scene,
    });
    setLoadKey(`${currentDocumentRef.current.id}:${Date.now()}`);
    window.setTimeout(() => {
      loadingRef.current = false;
      markDirty(false);
    }, 250);
  }, [clearAutosave, markDirty]);

  const createBlank = useCallback((payload = {}) => {
    clearAutosave();
    loadingRef.current = true;
    const scene = createBlankExcalidrawScene(payload.title || "Novo desenho");
    setReadonly(Boolean(payload.readonly));
    currentDocumentRef.current = {
      id: payload.id || "blank",
      path: payload.path || "",
      title: payload.title || "Novo desenho",
      originalContent: serializePlainExcalidraw(scene),
      format: "json",
    };
    setDocumentState({
      id: currentDocumentRef.current.id,
      title: currentDocumentRef.current.title,
      path: currentDocumentRef.current.path,
      scene,
    });
    setLoadKey(`${currentDocumentRef.current.id}:${Date.now()}`);
    window.setTimeout(() => {
      loadingRef.current = false;
      markDirty(false);
    }, 250);
  }, [clearAutosave, markDirty]);

  useEffect(() => {
    window.PocketExcalidrawDesktop = {
      receive(message) {
        switch (message?.command) {
          case "loadDocument":
            loadDocument(message);
            break;
          case "setViewMode":
            setReadonly(Boolean(message.readonly));
            break;
          case "requestSave":
            sendSave("saveRequested", message.mode === "export" ? "export" : "document", "manual");
            break;
          case "createBlank":
            createBlank(message);
            break;
          default:
            post("error", { message: `Comando desconhecido: ${message?.command || "vazio"}` });
        }
      },
    };
    post("ready", {});
    return () => {
      delete window.PocketExcalidrawDesktop;
    };
  }, [createBlank, loadDocument, sendSave]);

  useEffect(() => {
    const onKeyDown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        if (!readonly) {
          sendSave("saveRequested", "document", "manual");
        }
      }
    };
    window.addEventListener("keydown", onKeyDown, { capture: true });
    return () => window.removeEventListener("keydown", onKeyDown, { capture: true });
  }, [readonly, sendSave]);

  const onChange = useCallback(() => {
    if (loadingRef.current || readonly || !currentDocumentRef.current) return;
    if (!dirtyRef.current) markDirty(true);
    clearAutosave();
    autosaveTimerRef.current = window.setTimeout(() => {
      sendSave("autosaveRequested", "document", "autosave");
    }, AUTOSAVE_DELAY_MS);
  }, [clearAutosave, markDirty, readonly, sendSave]);

  const initialData = useMemo(() => {
    if (!documentState?.scene) return null;
    return {
      elements: documentState.scene.elements || [],
      appState: {
        ...(documentState.scene.appState || {}),
        theme: "dark",
      },
      files: documentState.scene.files || {},
      scrollToContent: true,
    };
  }, [documentState]);

  return (
    <main className="pocket-excalidraw-shell">
      {documentState && initialData ? (
        <div className="pocket-excalidraw-canvas">
          <Excalidraw
            key={loadKey}
            excalidrawAPI={(api) => {
              apiRef.current = api;
            }}
            initialData={initialData}
            onChange={onChange}
            name={documentState.title}
            theme="dark"
            viewModeEnabled={readonly}
            UIOptions={{
              canvasActions: {
                changeViewBackgroundColor: true,
                clearCanvas: !readonly,
                export: { saveFileToDisk: true },
                loadScene: !readonly,
                saveToActiveFile: false,
                toggleTheme: true,
              },
            }}
          >
            <MainMenu>
              <MainMenu.DefaultItems.LoadScene />
              <MainMenu.DefaultItems.Export />
              <MainMenu.DefaultItems.SaveAsImage />
              <MainMenu.DefaultItems.Help />
              <MainMenu.DefaultItems.ClearCanvas />
              <MainMenu.DefaultItems.ToggleTheme />
              <MainMenu.DefaultItems.ChangeCanvasBackground />
            </MainMenu>
            <WelcomeScreen />
          </Excalidraw>
        </div>
      ) : (
        <div className="pocket-excalidraw-empty">
          <strong>{error || "Nenhum desenho carregado"}</strong>
          <span>Selecione ou crie um arquivo Excalidraw no PocketWiki.</span>
        </div>
      )}
      <div className="pocket-excalidraw-status" data-dirty={isDirty ? "true" : "false"}>
        {readonly ? "somente leitura" : isDirty ? "alteracoes pendentes" : "salvo"}
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")).render(<PocketExcalidrawApp />);

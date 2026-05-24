import SwiftUI

struct ExcalidrawView: View {
    @Bindable var store: WikiAppStore
    @State private var selectedID: String?
    @State private var saveRequestID = 0
    @State private var exportRequestID = 0
    @State private var createBlankRequestID = 0
    @State private var webReady = false
    @State private var isDirty = false
    @State private var status: EditorStatus = .idle

    private var drawings: [WikiPage] {
        store.index.pages.filter { $0.kind == .excalidraw }
    }

    private var selectedPage: WikiPage? {
        if let selectedID, let page = store.index.page(id: selectedID), page.kind == .excalidraw {
            return page
        }
        if let page = store.selectedPage, page.kind == .excalidraw {
            return page
        }
        return drawings.first
    }

    private var selectedDocument: ExcalidrawEditorDocument? {
        guard let selectedPage else { return nil }
        return ExcalidrawEditorDocument(
            id: selectedPage.id,
            title: selectedPage.title,
            path: selectedPage.path,
            content: store.rawContent(for: selectedPage) ?? selectedPage.content,
            readonly: !store.canEditExcalidrawDocuments
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(PocketWikiTheme.bg2.opacity(0.96))

            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)

            if drawings.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        .background(PocketWikiTheme.appBackground)
        .onAppear {
            syncSelectionFromStore()
        }
        .onChange(of: store.selectedPageID) { _, _ in
            syncSelectionFromStore()
        }
        .onChange(of: drawings.map(\.id)) { _, _ in
            syncSelectionFromStore()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "scribble.variable")
                .foregroundStyle(PocketWikiTheme.purple)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPage?.title ?? "Excalidraw")
                    .font(.headline)
                    .foregroundStyle(PocketWikiTheme.text)
                    .lineLimit(1)
                Text(selectedPage?.path ?? sourceHint)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            if !drawings.isEmpty {
                Picker("", selection: bindingSelectedID) {
                    ForEach(drawings) { drawing in
                        Text(drawing.title).tag(drawing.id)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }

            statusPill

            Button {
                createDocument()
            } label: {
                Image(systemName: "plus")
            }
            .help("Criar Excalidraw")
            .disabled(!store.canEditExcalidrawDocuments)

            Button {
                saveRequestID += 1
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .help("Salvar")
            .disabled(!canSave)

            Button {
                exportRequestID += 1
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("Salvar como .excalidraw")
            .disabled(selectedDocument == nil || !webReady)

            Button {
                if let selectedPage {
                    store.selectPage(selectedPage.id, tab: .reader)
                }
            } label: {
                Image(systemName: "doc.text")
            }
            .help("Abrir indice textual")
            .disabled(selectedPage == nil)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .controlSize(.small)
    }

    private var editor: some View {
        ExcalidrawWebView(
            document: selectedDocument,
            saveRequestID: saveRequestID,
            exportRequestID: exportRequestID,
            createBlankRequestID: createBlankRequestID,
            onEvent: handleEditorEvent
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 0)
                .stroke(PocketWikiTheme.border.opacity(0.7), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                title: "Nenhum Excalidraw encontrado",
                message: store.canEditExcalidrawDocuments
                    ? "Crie um desenho novo ou carregue arquivos .excalidraw na pasta da wiki."
                    : "A fonte atual esta em modo somente leitura ou ainda nao ha pasta local aberta.",
                systemImage: "scribble.variable"
            )
            Button {
                createDocument()
            } label: {
                Label("Criar Excalidraw", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(PocketWikiTheme.accent)
            .disabled(!store.canEditExcalidrawDocuments)
            .padding(.bottom, 28)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusTitle)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(PocketWikiTheme.bg3.opacity(0.82), in: Capsule())
        .overlay {
            Capsule()
                .stroke(PocketWikiTheme.border, lineWidth: 1)
        }
        .frame(minWidth: 112)
    }

    private var bindingSelectedID: Binding<String> {
        Binding(
            get: { selectedPage?.id ?? drawings.first?.id ?? "" },
            set: { nextID in
                selectedID = nextID
                isDirty = false
                status = .idle
                store.selectPage(nextID, tab: .excalidraw)
            }
        )
    }

    private var canSave: Bool {
        selectedDocument != nil && webReady && store.canEditExcalidrawDocuments
    }

    private var sourceHint: String {
        store.canEditExcalidrawDocuments ? "pasta local editavel" : "somente leitura"
    }

    private var statusTitle: String {
        if selectedDocument?.readonly == true { return "readonly" }
        if case .error = status { return "erro" }
        if !webReady { return "carregando" }
        if isDirty { return "alterado" }
        switch status {
        case .idle: return "salvo"
        case .saving(let autosave): return autosave ? "autosave" : "salvando"
        case .saved: return "salvo"
        case .error: return "erro"
        }
    }

    private var statusColor: Color {
        if selectedDocument?.readonly == true { return PocketWikiTheme.muted }
        if case .error = status { return PocketWikiTheme.bad }
        if !webReady { return PocketWikiTheme.warn }
        if isDirty { return PocketWikiTheme.warn }
        switch status {
        case .idle, .saved: return PocketWikiTheme.good
        case .saving: return PocketWikiTheme.accent2
        case .error: return PocketWikiTheme.bad
        }
    }

    private func syncSelectionFromStore() {
        if let page = store.selectedPage, page.kind == .excalidraw {
            selectedID = page.id
        } else if let selectedID, drawings.contains(where: { $0.id == selectedID }) {
            return
        } else {
            selectedID = drawings.first?.id
        }
    }

    private func handleEditorEvent(_ event: ExcalidrawEditorEvent) {
        switch event {
        case .ready:
            webReady = true
            if case .error = status {
                status = .idle
            }
        case .diagnostic(let message):
            #if DEBUG
            print("PocketWiki Excalidraw diagnostic: \(message)")
            #endif
        case .dirtyChanged(_, let path, let dirty):
            guard selectedPage?.path == path else { return }
            isDirty = dirty
            if dirty { status = .idle }
        case .saveRequested(let payload):
            Task { await persist(payload, autosave: false) }
        case .autosaveRequested(let payload):
            Task { await persist(payload, autosave: true) }
        case .error(_, let path, let message):
            if path.isEmpty || selectedPage?.path == path {
                status = .error(message)
            }
        }
    }

    private func persist(_ payload: ExcalidrawSavePayload, autosave: Bool) async {
        if payload.saveMode == "export" {
            do {
                try await store.exportPlainExcalidraw(content: payload.content, suggestedName: payload.title)
                status = .saved(Date())
            } catch {
                status = .error(error.localizedDescription)
            }
            return
        }

        guard store.canEditExcalidrawDocuments else {
            status = .error("Fonte somente leitura.")
            return
        }

        status = .saving(autosave: autosave)
        do {
            try await store.saveExcalidrawDocument(path: payload.path, content: payload.content)
            selectedID = store.selectedPageID
            isDirty = false
            status = .saved(Date())
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func createDocument() {
        Task {
            do {
                let page = try await store.createExcalidrawDocument(near: selectedPage)
                selectedID = page?.id
                if let page {
                    store.selectPage(page.id, tab: .excalidraw)
                } else {
                    createBlankRequestID += 1
                }
                status = .saved(Date())
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}

private enum EditorStatus: Equatable {
    case idle
    case saving(autosave: Bool)
    case saved(Date)
    case error(String)
}

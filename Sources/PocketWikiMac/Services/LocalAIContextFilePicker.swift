import AppKit
import Foundation

enum LocalAIContextFilePickerError: Error, LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "Nao consegui ler \(name) como texto."
        }
    }
}

struct LocalAIContextFilePicker {
    private static let maxFileCharacters = 40_000

    @MainActor
    static func pickFiles() throws -> [LocalAIManualContextSource] {
        let panel = NSOpenPanel()
        panel.title = "Adicionar contexto"
        panel.prompt = "Adicionar"
        panel.message = "Escolha um ou mais arquivos de texto para anexar ao contexto da proxima resposta."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return [] }
        return try panel.urls.map(loadSource)
    }

    private static func loadSource(from url: URL) throws -> LocalAIManualContextSource {
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            if content.count > maxFileCharacters {
                content = String(content.prefix(maxFileCharacters)) + "\n\n[contexto truncado pelo PocketWiki]"
            }
            return LocalAIManualContextSource(
                title: url.lastPathComponent,
                path: url.path,
                content: content
            )
        } catch {
            throw LocalAIContextFilePickerError.unreadable(url.lastPathComponent)
        }
    }
}

import AppKit
import Foundation

@MainActor
struct WikiFolderPicker {
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Abrir pasta da wiki"
        panel.prompt = "Abrir"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        return panel.runModal() == .OK ? panel.url : nil
    }
}

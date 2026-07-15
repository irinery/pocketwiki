import Darwin
import Foundation

struct WikiFolderLoader {
    static let maxFileSizeBytes = 5 * 1024 * 1024
    static let maxMarkdownFileSizeBytes = maxFileSizeBytes
    static let maxExcalidrawFileSizeBytes = 50 * 1024 * 1024

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadFiles(from root: URL) throws -> (files: [WikiFile], issues: [String]) {
        var files: [WikiFile] = []
        var issues: [String] = []
        let canonicalRoot = canonicalURL(root)
        try walk(root: canonicalRoot, current: canonicalRoot, files: &files, issues: &issues)
        return (files.sorted { $0.relativePath < $1.relativePath }, issues)
    }

    private func canonicalURL(_ url: URL) -> URL {
        let resolved = url.path.withCString { realpath($0, nil) }
        guard let resolved else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).standardizedFileURL
    }

    func isEligible(relativePath: String, isDirectory: Bool, sizeBytes: Int? = nil) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)

        if parts.contains(where: shouldIgnoreComponent) { return false }
        if isDirectory { return true }
        guard let kind = kind(for: normalized) else { return false }
        if let sizeBytes, sizeBytes > Self.maxFileSizeBytes(for: kind) { return false }
        return true
    }

    func kind(for relativePath: String) -> WikiFile.Kind? {
        let lower = relativePath.lowercased()
        if lower.hasSuffix(".excalidraw.md") { return .excalidrawMarkdown }
        if lower.hasSuffix(".excalidraw") { return .excalidraw }
        if lower.hasSuffix(".md") { return .markdown }
        return nil
    }

    private func walk(root: URL, current: URL, files: inout [WikiFile], issues: inout [String]) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        )

        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let rootPath = comparableFileSystemPath(root.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let childPath = comparableFileSystemPath(url.path)
            let rootPrefix = "/\(rootPath)/"
            guard childPath.hasPrefix(rootPrefix) else {
                issues.append("path fora da raiz ignorado: \(url.lastPathComponent)")
                continue
            }
            let relativePath = String(childPath.dropFirst(rootPrefix.count))
            let isDirectory = values.isDirectory == true

            guard isEligible(relativePath: relativePath, isDirectory: isDirectory, sizeBytes: values.fileSize) else {
                appendIgnoredFileIssueIfNeeded(relativePath: relativePath, isDirectory: isDirectory, sizeBytes: values.fileSize, issues: &issues)
                continue
            }

            if isDirectory {
                try walk(root: root, current: url, files: &files, issues: &issues)
                continue
            }

            guard let kind = kind(for: relativePath) else { continue }
            let size = values.fileSize ?? 0

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                files.append(WikiFile(
                    relativePath: relativePath,
                    sizeBytes: size,
                    modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    content: content,
                    kind: kind
                ))
            } catch {
                issues.append("nao foi possivel ler \(relativePath)")
            }
        }
    }

    private func comparableFileSystemPath(_ path: String) -> String {
        for (canonical, alias) in [("/private/var", "/var"), ("/private/tmp", "/tmp"), ("/private/etc", "/etc")] {
            if path == canonical { return alias }
            if path.hasPrefix("\(canonical)/") {
                return alias + path.dropFirst(canonical.count)
            }
        }
        return path
    }

    private func appendIgnoredFileIssueIfNeeded(relativePath: String, isDirectory: Bool, sizeBytes: Int?, issues: inout [String]) {
        let parts = relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.contains(where: shouldIgnoreComponent) else { return }
        guard !isDirectory,
              let kind = kind(for: relativePath),
              isExcalidrawKind(kind),
              let sizeBytes,
              sizeBytes > Self.maxFileSizeBytes(for: kind) else {
            return
        }

        let limitMB = Self.maxFileSizeBytes(for: kind) / 1024 / 1024
        issues.append("excalidraw ignorado por tamanho acima de \(limitMB) MB: \(relativePath)")
    }

    private func shouldIgnoreComponent(_ component: String) -> Bool {
        if component.hasPrefix(".") { return true }
        return ["node_modules", "dist", "build"].contains(component)
    }

    private func isExcalidrawKind(_ kind: WikiFile.Kind) -> Bool {
        switch kind {
        case .excalidraw, .excalidrawMarkdown:
            return true
        case .markdown:
            return false
        }
    }

    private static func maxFileSizeBytes(for kind: WikiFile.Kind) -> Int {
        switch kind {
        case .excalidraw, .excalidrawMarkdown:
            return maxExcalidrawFileSizeBytes
        case .markdown:
            return maxMarkdownFileSizeBytes
        }
    }
}

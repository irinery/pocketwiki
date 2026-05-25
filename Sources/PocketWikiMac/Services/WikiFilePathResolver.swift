import Foundation

enum WikiFilePathResolverError: Error, LocalizedError, Equatable {
    case invalidRelativePath
    case pathEscapesRoot

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Path relativo invalido."
        case .pathEscapesRoot:
            "Path sai da raiz da wiki."
        }
    }
}

enum WikiFilePathResolver {
    static func fileURL(root: URL, relativePath: String) throws -> URL {
        let clean = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        guard !clean.isEmpty,
              !relativePath.hasPrefix("/"),
              !clean.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw WikiFilePathResolverError.invalidRelativePath
        }

        let rootURL = root.standardizedFileURL
        let target = clean.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard target.path.hasPrefix(rootPath) else {
            throw WikiFilePathResolverError.pathEscapesRoot
        }

        return target
    }
}


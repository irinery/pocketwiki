import Foundation

struct PocketWikiMCPEvidenceStatus: Codable, Equatable, Sendable {
    static let toolNames = ["wiki.search", "wiki.get_document"]
    static let timeoutMs = 5_000
    static let maxResults = 8

    let available: Bool
    let transport: String
    let status: String
    let command: String
    let args: [String]
    let tools: [String]
    let timeoutMs: Int
    let maxResults: Int
    let sameHostOnly: Bool
    let argsParsing: String
    let argsPortable: Bool
    let note: String

    var title: String {
        if status == "ready" { return "Pronto via stdio" }
        return available ? "Ajuste necessario" : "Nao disponivel"
    }

    var commandLine: String {
        ([command] + args).map(Self.shellEscaped).joined(separator: " ")
    }

    var pocketKernelEnv: String {
        """
        POCKETKERNEL_WIKI_MCP_COMMAND=\(command)
        POCKETKERNEL_WIKI_MCP_ARGS=\(args.joined(separator: " "))
        POCKETKERNEL_WIKI_MCP_TIMEOUT_MS=\(timeoutMs)
        POCKETKERNEL_WIKI_MCP_MAX_RESULTS=\(maxResults)
        """
    }

    var jsonValue: JSONValue {
        .object([
            "available": .bool(available),
            "transport": .string(transport),
            "status": .string(status),
            "command": .string(command),
            "args": .array(args.map(JSONValue.string)),
            "tools": .array(tools.map(JSONValue.string)),
            "timeoutMs": .int(timeoutMs),
            "maxResults": .int(maxResults),
            "sameHostOnly": .bool(sameHostOnly),
            "argsParsing": .string(argsParsing),
            "argsPortable": .bool(argsPortable),
            "note": .string(note)
        ])
    }

    static func make(
        rootPath: String,
        rootAvailable: Bool? = nil,
        rootStatus: String? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> PocketWikiMCPEvidenceStatus {
        let scriptPath = mcpServerScriptPath(bundle: bundle, fileManager: fileManager)
        let scriptExists = fileManager.fileExists(atPath: scriptPath)
        let inspectedRoot = inspectRoot(path: rootPath, fileManager: fileManager)
        let resolvedRootAvailable = rootAvailable ?? inspectedRoot.available
        let resolvedRootStatus = rootStatus ?? inspectedRoot.status
        let args = [scriptPath, "--root", rootPath]
        let argsPortable = args.allSatisfy { !$0.contains(where: \.isWhitespace) }

        let status: String
        if !scriptExists {
            status = "mcp_script_missing"
        } else if !resolvedRootAvailable {
            status = resolvedRootStatus
        } else if !argsPortable {
            status = "args_require_wrapper"
        } else {
            status = "ready"
        }

        return PocketWikiMCPEvidenceStatus(
            available: scriptExists && resolvedRootAvailable && argsPortable,
            transport: "stdio",
            status: status,
            command: "node",
            args: args,
            tools: toolNames,
            timeoutMs: timeoutMs,
            maxResults: maxResults,
            sameHostOnly: true,
            argsParsing: "space_separated",
            argsPortable: argsPortable,
            note: "PocketKernel inicia este processo sob demanda via stdio; nao ha porta MCP separada."
        )
    }

    static func repositoryRootPath(bundle: Bundle = .main, fileManager: FileManager = .default) -> String {
        if let rootPath = bundle.object(forInfoDictionaryKey: "PocketWikiRootPath") as? String,
           !rootPath.pocketTrimmed.isEmpty {
            return URL(fileURLWithPath: rootPath).standardizedFileURL.path
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL.path
    }

    private static func mcpServerScriptPath(bundle: Bundle, fileManager: FileManager) -> String {
        URL(fileURLWithPath: repositoryRootPath(bundle: bundle, fileManager: fileManager))
            .appendingPathComponent("src/mcp/pocketwiki-mcp-server.mjs")
            .standardizedFileURL
            .path
    }

    private static func inspectRoot(path: String, fileManager: FileManager) -> (available: Bool, status: String) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return (false, "missing")
        }
        return isDirectory.boolValue ? (true, "ready") : (false, "not_directory")
    }

    private static func shellEscaped(_ value: String) -> String {
        guard value.contains(where: \.isWhitespace) || value.contains("'") else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

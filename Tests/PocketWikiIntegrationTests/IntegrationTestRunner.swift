import Darwin
import CryptoKit
import Foundation

enum IntegrationTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw IntegrationTestFailure.failed(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw IntegrationTestFailure.failed(message)
    }
    return value
}

@main
struct IntegrationTestRunner {
    static func main() async throws {
        let tests: [(String, () async throws -> Void)] = [
            ("native server http contract", testNativeServerHTTPContract),
            ("native solutions ingestion contract", testNativeSolutionsIngestionContract),
            ("remote client against native server", testRemoteClientAgainstNativeServer),
            ("web runtime assets", testWebRuntimeAssets),
            ("excalidraw editor bundle resolver", testExcalidrawEditorBundleResolver)
        ]

        for (name, test) in tests {
            try await test()
            print("ok - \(name)")
        }

        print("\(tests.count) integration tests passing")
    }

    static func testNativeServerHTTPContract() async throws {
        try await withRunningServer { baseURL, _, logs in
            let indexResponse = try await request(baseURL.appendingPathComponent("/"))
            try expect(indexResponse.status == 200, "index status failed")
            try expect(indexResponse.contentType?.contains("text/html") == true, "index content type failed")
            try expect(indexResponse.text.contains("PocketWiki"), "index html missing app name")

            let headResponse = try await request(baseURL.appendingPathComponent("/"), method: "HEAD")
            try expect(headResponse.status == 200, "HEAD index status failed")
            try expect(headResponse.body.isEmpty, "HEAD index returned body")

            let configResponse = try await request(baseURL.appendingPathComponent("/api/config"))
            let config = try jsonObject(configResponse.body)
            try expect(configResponse.status == 200, "config status failed")
            try expect(config["referenceName"] as? String == "IntegrationWiki", "config referenceName failed")
            try expect(config["referenceAvailable"] as? Bool == true, "config availability failed")
            try expect(config["kernelProxy"] as? Bool == true, "config kernelProxy failed")

            let routesResponse = try await request(baseURL.appendingPathComponent("/api/routes"))
            let routes = try JSONDecoder().decode(PocketWikiRouteSnapshot.self, from: routesResponse.body)
            try expect(routes.local.contains(baseURL.absoluteString), "routes local url missing")
            try expect(routes.bindHost == "127.0.0.1", "routes bind host failed")

            let filesResponse = try await request(baseURL.appendingPathComponent("/api/wiki/files"))
            let files = try jsonObject(filesResponse.body)
            let payloadFiles = try require(files["files"] as? [[String: Any]], "files array missing")
            try expect(filesResponse.status == 200, "files status failed")
            try expect(files["rootName"] as? String == "IntegrationWiki", "files rootName failed")
            try expect(payloadFiles.count == sampleFiles.count, "files count failed")
            try expect(payloadFiles.contains { $0["path"] as? String == "wiki/index.md" }, "index file missing")

            let assetResponse = try await request(baseURL.appendingPathComponent("/assets/favicon.png"))
            try expect(assetResponse.status == 200, "asset status failed")
            try expect(assetResponse.contentType == "image/png", "asset content type failed")

            let missingResponse = try await request(baseURL.appendingPathComponent("/api/unknown"))
            try expect(missingResponse.status == 404, "api missing status failed")
            try expect(missingResponse.text.contains("not_found"), "api missing body failed")

            let messages = await logs.messages
            try expect(messages.contains("GET /"), "server did not log index request")
            try expect(messages.contains("GET /api/config"), "server did not log config request")
            try expect(messages.contains("GET /api/wiki/files"), "server did not log files request")
        }
    }

    static func testNativeSolutionsIngestionContract() async throws {
        let requestedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketWikiSolutions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        let root = requestedRoot.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let port = try availablePort()
        let config = serverConfiguration(
            port: port,
            referencePath: root.path,
            referenceReadonly: false,
            writeToken: "integration-write-token"
        )
        let server = PocketWikiHTTPServer(
            configuration: config,
            sourceProvider: {
                let files = (try? WikiFolderLoader().loadFiles(from: root).files) ?? []
                return PocketWikiServedSource(
                    rootName: root.lastPathComponent,
                    rootPath: root.path,
                    source: "integration",
                    configured: true,
                    readonly: false,
                    available: true,
                    status: "ready",
                    files: files
                )
            },
            log: { _ in }
        )
        _ = try await server.start()
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(baseURL: baseURL)

        let payload = try solutionPayload()
        let endpoint = baseURL.appendingPathComponent("api/v1/solutions/solution_native")
        let headers = [
            "Authorization": "Bearer integration-write-token",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Idempotency-Key": "solution_native:doc_v1"
        ]
        let created = try await request(endpoint, method: "PUT", headers: headers, body: payload)
        try expect(created.status == 201, "native solution create status failed: \(created.text)")
        let createdJSON = try jsonObject(created.body)
        let revision = try require(createdJSON["remote_revision"] as? String, "native solution revision missing")
        try expect(revision.range(of: #"^"sha256:[a-f0-9]{64}"$"#, options: .regularExpression) != nil, "native revision format failed")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("solutions/solution_native.md").path), "native solution file missing")

        let replay = try await request(endpoint, method: "PUT", headers: headers, body: payload)
        try expect(replay.status == 201, "native idempotency replay failed")
        try expect(replay.body == created.body, "native idempotency response changed")

        let filesResponse = try await request(baseURL.appendingPathComponent("api/wiki/files"))
        let filesJSON = try jsonObject(filesResponse.body)
        let files = try require(filesJSON["files"] as? [[String: Any]], "native solution files missing")
        try expect(
            files.contains { $0["path"] as? String == "solutions/solution_native.md" },
            "native solution not indexed: \(filesResponse.text)"
        )

        let unauthorized = try await request(
            endpoint,
            method: "PUT",
            headers: headers.merging(["Authorization": "Bearer invalid-token"]) { _, new in new },
            body: payload
        )
        try expect(unauthorized.status == 401, "native unauthorized status failed")
        try expect(!unauthorized.text.contains("integration-write-token"), "native response leaked token")
    }

    static func testRemoteClientAgainstNativeServer() async throws {
        try await withRunningServer { baseURL, _, _ in
            let result = try await RemoteWikiClient().connect(to: baseURL.absoluteString)
            try expect(result.baseURL == baseURL, "remote base url failed")
            try expect(result.config.referenceName == "IntegrationWiki", "remote config failed")
            try expect(result.source.files.map(\.relativePath).sorted() == sampleFiles.map(\.relativePath).sorted(), "remote files failed")

            let index = WikiIndexer().buildIndex(files: result.source.files, sourceName: result.source.rootName)
            let home = try require(index.page(id: "index"), "remote index page missing")
            let ops = try require(index.page(id: "ops"), "remote ops page missing")
            try expect(home.outlinks.first?.resolvedPageID == ops.id, "remote outlink resolution failed")
            try expect(ops.backlinks == [home.id], "remote backlink resolution failed")
            try expect(index.missingLinks["missing-runbook"] == [ops.id], "remote missing link failed")
        }
    }

    static func testWebRuntimeAssets() async throws {
        let root = try PocketWikiWebRuntimeResolver.webRoot()
        try expect(root.appendingPathComponent("wiki-cockpit.html").path.hasSuffix("wiki-cockpit.html"), "web root did not resolve cockpit")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/favicon.png").path), "favicon asset missing")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sw.js").path), "service worker missing")
    }

    static func testExcalidrawEditorBundleResolver() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/PocketWikiMac/Resources/ExcalidrawEditor", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path), "excalidraw index missing")

        let resolver = ExcalidrawEditorResourceResolver(root: root)
        let indexURL = try require(URL(string: "pocketwiki-excalidraw://bundle/index.html"), "excalidraw index url failed")
        let index = try resolver.resolve(indexURL)
        try expect(index.mimeType == "text/html", "excalidraw index mime failed")
        try expect(String(data: index.data, encoding: .utf8)?.contains("PocketWiki Excalidraw") == true, "excalidraw index title missing")

        let assetNames = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        let js = try require(assetNames.first { $0.hasSuffix(".js") }, "excalidraw js asset missing")
        let css = try require(assetNames.first { $0.hasSuffix(".css") }, "excalidraw css asset missing")
        let font = try require(assetNames.first { $0.hasSuffix(".woff2") }, "excalidraw font asset missing")

        let jsResource = try resolver.resolve(try require(URL(string: "pocketwiki-excalidraw://bundle/assets/\(js)"), "js url failed"))
        let cssResource = try resolver.resolve(try require(URL(string: "pocketwiki-excalidraw://bundle/assets/\(css)"), "css url failed"))
        let fontResource = try resolver.resolve(try require(URL(string: "pocketwiki-excalidraw://bundle/assets/\(font)"), "font url failed"))
        try expect(jsResource.mimeType == "text/javascript", "excalidraw js mime failed")
        try expect(cssResource.mimeType == "text/css", "excalidraw css mime failed")
        try expect(fontResource.mimeType == "font/woff2", "excalidraw font mime failed")
    }

    private static func withRunningServer(_ body: (URL, PocketWikiHTTPServer, IntegrationLogSink) async throws -> Void) async throws {
        let port = try availablePort()
        let config = serverConfiguration(port: port)
        let logs = IntegrationLogSink()
        let server = PocketWikiHTTPServer(
            configuration: config,
            sourceProvider: {
                PocketWikiServedSource(
                    rootName: "IntegrationWiki",
                    source: "integration",
                    configured: true,
                    readonly: true,
                    available: true,
                    status: "ready",
                    files: sampleFiles
                )
            },
            log: { entry in
                Task { await logs.append(entry.message) }
            }
        )

        _ = try await server.start()
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(baseURL: baseURL)
        try await body(baseURL, server, logs)
    }

    private static func waitUntilReady(baseURL: URL) async throws {
        var lastError: Error?
        for _ in 0..<20 {
            do {
                let response = try await request(baseURL.appendingPathComponent("/api/config"))
                if response.status == 200 { return }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntegrationTestFailure.failed("server did not become ready: \(lastError?.localizedDescription ?? "unknown")")
    }

    private static func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try require(response as? HTTPURLResponse, "non-http response")
        return HTTPResult(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            body: data
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try require(object as? [String: Any], "json object missing")
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IntegrationTestFailure.failed("socket failed") }
        defer { close(fd) }

        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw IntegrationTestFailure.failed("bind for free port failed") }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw IntegrationTestFailure.failed("getsockname failed") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func serverConfiguration(
        port: Int,
        referencePath: String = "",
        referenceReadonly: Bool = true,
        writeToken: String = ""
    ) -> PocketWikiServerConfiguration {
        PocketWikiServerConfiguration(
            port: port,
            bindHost: "127.0.0.1",
            publicHosts: [],
            mdnsEnabled: false,
            referencePath: referencePath,
            referenceReadonly: referenceReadonly,
            writeToken: writeToken,
            writeMaxBytes: PocketWikiSolutionIngestion.minimumRequestBytes,
            lmStudioBaseURL: "http://127.0.0.1:9/v1",
            lmStudioAPIKey: "",
            lmStudioModel: "",
            pocketKernelBaseURL: "http://127.0.0.1:9",
            middlewareAuthBaseURL: "http://127.0.0.1:9",
            middlewareAuthClientToken: "",
            middlewareAuthProjectID: "acme",
            middlewareAuthProfileID: "default",
            envPath: nil
        )
    }

    private static func solutionPayload() throws -> Data {
        var payload: [String: Any] = [
            "schema_version": "pockettrace.pocketwiki_solution.v1",
            "generator_version": "pockettrace.processor.v1",
            "input_hash": String(repeating: "a", count: 64),
            "output_hash": "",
            "solution_id": "solution_native",
            "document_version": "doc_v1",
            "trace_or_context_id": "pt_native",
            "title": "Solução nativa",
            "summary": "Validação do servidor Swift.",
            "body_markdown": "# Solução nativa\n\nDocumento persistido.",
            "category": "infraestrutura",
            "tags": ["swift", "smoke"],
            "replicability_level": "R1",
            "mvp5_candidate": false,
            "source_hashes": [[
                "path": "ai/runs/native/validated_output.json",
                "artifact_type": "ai_validated_output_json",
                "schema_version": "pockettrace.ai_validated_enrichment.v1",
                "sha256": String(repeating: "c", count: 64)
            ]],
            "publish_mode": "ai_enriched"
        ]
        let canonical = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        payload["output_hash"] = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static var sampleFiles: [WikiFile] {
        [
            makeFile(path: "wiki/index.md", content: "# Index\n\nHome da wiki [[Ops]]."),
            makeFile(path: "wiki/Ops.md", content: "# Ops\n\nRunbook principal com [[Missing Runbook]]."),
            makeFile(
                path: "drawings/topology.excalidraw",
                content: #"{"type":"excalidraw","elements":[{"id":"1","type":"text","rawText":"Mapa [[Index]]"}]}"#,
                kind: .excalidraw
            )
        ]
    }

    private static func makeFile(path: String, content: String, kind: WikiFile.Kind = .markdown) -> WikiFile {
        WikiFile(
            relativePath: path,
            sizeBytes: content.utf8.count,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: content,
            kind: kind
        )
    }
}

actor IntegrationLogSink {
    private var storage: [String] = []

    var messages: [String] { storage }

    func append(_ message: String) {
        storage.append(message)
    }
}

struct HTTPResult {
    let status: Int
    let contentType: String?
    let body: Data

    var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

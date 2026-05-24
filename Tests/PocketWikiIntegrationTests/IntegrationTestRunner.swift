import Darwin
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
            ("remote client against native server", testRemoteClientAgainstNativeServer),
            ("web runtime assets", testWebRuntimeAssets)
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
            try expect(config["aiProxy"] as? Bool == true, "config aiProxy failed")

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

    private static func withRunningServer(_ body: (URL, PocketWikiHTTPServer, IntegrationLogSink) async throws -> Void) async throws {
        let port = try availablePort()
        let config = PocketWikiServerConfiguration(
            port: port,
            bindHost: "127.0.0.1",
            publicHosts: [],
            mdnsEnabled: false,
            referencePath: "",
            referenceReadonly: true,
            lmStudioBaseURL: "http://127.0.0.1:9/v1",
            lmStudioAPIKey: "",
            lmStudioModel: "",
            envPath: nil
        )
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

    private static func request(_ url: URL, method: String = "GET") async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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

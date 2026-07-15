import CryptoKit
import Foundation

actor PocketWikiSolutionIngestion {
    static let minimumRequestBytes = PocketWikiServerConfiguration.minimumWriteRequestBytes
    static let maximumMarkdownBytes = 5 * 1024 * 1024

    private let writeToken: String

    init(writeToken: String) {
        self.writeToken = writeToken
    }

    func handle(
        request: PocketWikiHTTPRequest,
        solutionID: String,
        source: PocketWikiServedSource,
        configuredRoot: URL
    ) -> PocketWikiHTTPResponse {
        if source.readonly {
            return error("write_disabled", "A base de referência está em modo somente leitura.", status: 403)
        }
        guard source.available else {
            return error("reference_unavailable", "A base de referência configurada não está disponível.", status: 404)
        }
        guard !writeToken.isEmpty else {
            return error("write_unavailable", "A credencial de escrita não está configurada no servidor.", status: 503)
        }
        guard validBearer(request.headers["authorization"]) else {
            return error("unauthorized", "Credencial de escrita ausente ou inválida.", status: 401)
        }
        guard request.headers["content-type"]?.range(
            of: #"^application/json(?:\s*;|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return error("unsupported_media_type", "Content-Type deve ser application/json.", status: 415)
        }
        guard Self.validSolutionID(solutionID) else {
            return error("invalid_request", "solution_id inválido no path.", status: 400)
        }
        guard let idempotencyKey = request.headers["idempotency-key"], !idempotencyKey.isEmpty else {
            return error("invalid_request", "Idempotency-Key é obrigatório.", status: 400)
        }

        let payload: PocketWikiSolutionPayload
        let rawObject: [String: Any]
        do {
            payload = try JSONDecoder().decode(PocketWikiSolutionPayload.self, from: request.body)
            guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                throw PocketWikiSolutionError.invalidJSON
            }
            rawObject = object
        } catch {
            return self.error("invalid_request", "O corpo precisa ser JSON UTF-8 válido.", status: 400)
        }

        guard payload.solutionID == solutionID else {
            return error("invalid_request", "solution_id do path e do JSON precisam ser iguais.", status: 400)
        }
        if let message = payload.validationError {
            return error("schema_validation_failed", message, status: 422)
        }
        guard idempotencyKey == "\(solutionID):\(payload.documentVersion)" else {
            return error("invalid_request", "Idempotency-Key não corresponde à solução e versão do documento.", status: 400)
        }

        let canonicalRequest: Data
        do {
            canonicalRequest = try Self.canonicalJSON(rawObject)
            var outputObject = rawObject
            outputObject["output_hash"] = ""
            let expected = Self.sha256(try Self.canonicalJSON(outputObject))
            guard expected == payload.outputHash else {
                return error("output_hash_mismatch", "output_hash não corresponde ao documento canônico recebido.", status: 422)
            }
        } catch {
            return self.error("schema_validation_failed", "Não foi possível serializar o documento canônico.", status: 422)
        }

        let root = source.rootPath.map { URL(fileURLWithPath: $0) } ?? configuredRoot
        do {
            return try persist(
                payload: payload,
                root: root,
                idempotencyKey: idempotencyKey,
                requestHash: Self.sha256(canonicalRequest),
                ifMatch: request.headers["if-match"]
            )
        } catch let failure as PocketWikiSolutionFailure {
            return response(status: failure.status, object: failure.body, headers: failure.headers)
        } catch {
            return self.error("write_failed", "Não foi possível persistir e indexar a solução.", status: 500)
        }
    }

    private func persist(
        payload: PocketWikiSolutionPayload,
        root: URL,
        idempotencyKey: String,
        requestHash: String,
        ifMatch: String?
    ) throws -> PocketWikiHTTPResponse {
        let paths = try safePaths(root: root, solutionID: payload.solutionID, idempotencyKey: idempotencyKey)
        let existing = try optionalData(paths.document)
        let currentRevision = existing.map(Self.revision)

        if let recordData = try optionalData(paths.idempotency) {
            let record = try JSONDecoder().decode(PocketWikiIdempotencyRecord.self, from: recordData)
            guard record.requestHash == requestHash else {
                throw conflict(
                    status: 409,
                    code: "idempotency_key_reused",
                    message: "A chave de idempotência já foi usada com outro payload.",
                    solutionID: payload.solutionID,
                    revision: currentRevision
                )
            }
            return response(
                status: record.status,
                object: record.response.object,
                headers: ["ETag": record.etag]
            )
        }

        if existing == nil, ifMatch != nil {
            throw conflict(
                status: 412,
                code: "remote_revision_mismatch",
                message: "If-Match não corresponde à revisão atual.",
                solutionID: payload.solutionID,
                revision: nil
            )
        }
        if existing != nil, ifMatch == nil {
            throw conflict(
                status: 409,
                code: "remote_conflict",
                message: "A solução já existe; informe a revisão remota para atualizar.",
                solutionID: payload.solutionID,
                revision: currentRevision
            )
        }
        if existing != nil, ifMatch != currentRevision {
            throw conflict(
                status: 412,
                code: "remote_revision_mismatch",
                message: "If-Match não corresponde à revisão atual.",
                solutionID: payload.solutionID,
                revision: currentRevision
            )
        }

        let document = Data(payload.renderedMarkdown.utf8)
        let etag = Self.revision(document)
        let status = existing == nil ? 201 : 200
        let logicalResponse = PocketWikiSolutionLogicalResponse(
            remoteID: payload.solutionID,
            remoteRevision: etag,
            message: existing == nil ? "created" : "updated"
        )
        let record = PocketWikiIdempotencyRecord(
            version: 1,
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            status: status,
            etag: etag,
            response: logicalResponse,
            storedAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordData = try encoder.encode(record)

        do {
            try document.write(to: paths.document, options: .atomic)
            guard try Data(contentsOf: paths.document) == document else {
                throw PocketWikiSolutionError.verificationFailed
            }
            try recordData.write(to: paths.idempotency, options: .atomic)
            guard try Data(contentsOf: paths.idempotency) == recordData else {
                throw PocketWikiSolutionError.verificationFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: paths.idempotency)
            if let existing {
                try? existing.write(to: paths.document, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: paths.document)
            }
            throw PocketWikiSolutionError.writeFailed
        }

        return response(status: status, object: logicalResponse.object, headers: ["ETag": etag])
    }

    private func safePaths(root: URL, solutionID: String, idempotencyKey: String) throws -> (document: URL, idempotency: URL) {
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PocketWikiSolutionError.writeFailed
        }
        let solutions = try ensureSafeDirectory(parent: canonicalRoot, name: "solutions")
        let state = try ensureSafeDirectory(parent: canonicalRoot, name: ".pocketwiki")
        let idempotency = try ensureSafeDirectory(parent: state, name: "solution-idempotency")
        let document = solutions.appendingPathComponent("\(solutionID).md")
        let record = idempotency.appendingPathComponent("\(Self.sha256(Data(idempotencyKey.utf8))).json")
        try rejectUnsafeTarget(document)
        try rejectUnsafeTarget(record)
        return (document, record)
    }

    private func ensureSafeDirectory(parent: URL, name: String) throws -> URL {
        let manager = FileManager.default
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PocketWikiSolutionError.unsafePath
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isWithin(parent: canonicalParent, child: canonicalDirectory) else {
            throw PocketWikiSolutionError.unsafePath
        }
        return canonicalDirectory
    }

    private func rejectUnsafeTarget(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PocketWikiSolutionError.unsafePath
        }
    }

    private func optionalData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func validBearer(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let supplied = String(header.dropFirst("Bearer ".count))
        guard !supplied.isEmpty, !supplied.contains(where: \.isWhitespace) else { return false }
        let left = Array(SHA256.hash(data: Data(supplied.utf8)))
        let right = Array(SHA256.hash(data: Data(writeToken.utf8)))
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private func conflict(
        status: Int,
        code: String,
        message: String,
        solutionID: String,
        revision: String?
    ) -> PocketWikiSolutionFailure {
        var body: [String: Any] = [
            "remote_id": solutionID,
            "remote_revision": revision ?? NSNull(),
            "error": code,
            "message": message
        ]
        if revision == nil { body["remote_revision"] = NSNull() }
        return PocketWikiSolutionFailure(status: status, body: body, headers: revision.map { ["ETag": $0] } ?? [:])
    }

    private func error(_ code: String, _ message: String, status: Int) -> PocketWikiHTTPResponse {
        response(status: status, object: ["error": code, "message": message])
    }

    private func response(status: Int, object: [String: Any], headers: [String: String] = [:]) -> PocketWikiHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var responseHeaders = headers
        responseHeaders["Cache-Control"] = "no-store"
        return PocketWikiHTTPResponse(
            status: status,
            headers: responseHeaders,
            body: data,
            contentType: "application/json; charset=utf-8"
        )
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func validSolutionID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func revision(_ data: Data) -> String {
        "\"sha256:\(sha256(data))\""
    }

    private static func isWithin(parent: URL, child: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : "\(parent.path)/"
        return child.path == parent.path || child.path.hasPrefix(parentPath)
    }
}

private struct PocketWikiSolutionPayload: Decodable {
    let schemaVersion: String
    let generatorVersion: String
    let inputHash: String
    let outputHash: String
    let solutionID: String
    let documentVersion: String
    let traceOrContextID: String
    let title: String
    let summary: String
    let bodyMarkdown: String
    let category: String?
    let tags: [String]
    let replicabilityLevel: String
    let mvp5Candidate: Bool
    let sourceHashes: [PocketWikiSolutionSourceHash]
    let publishMode: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatorVersion = "generator_version"
        case inputHash = "input_hash"
        case outputHash = "output_hash"
        case solutionID = "solution_id"
        case documentVersion = "document_version"
        case traceOrContextID = "trace_or_context_id"
        case title, summary
        case bodyMarkdown = "body_markdown"
        case category, tags
        case replicabilityLevel = "replicability_level"
        case mvp5Candidate = "mvp5_candidate"
        case sourceHashes = "source_hashes"
        case publishMode = "publish_mode"
    }

    var validationError: String? {
        if schemaVersion != "pockettrace.pocketwiki_solution.v1" { return "schema_version não suportado." }
        if !generatorVersion.isBoundedNonEmpty(max: 200) { return "generator_version inválido." }
        if !inputHash.isSHA256 || !outputHash.isSHA256 { return "Hash SHA-256 inválido." }
        if !solutionID.isSolutionID { return "solution_id inválido." }
        if !documentVersion.isBoundedNonEmpty(max: 200) { return "document_version inválido." }
        if !traceOrContextID.isBoundedNonEmpty(max: 200) { return "trace_or_context_id inválido." }
        if !title.isBoundedNonEmpty(max: 500) { return "title inválido." }
        if !summary.isBoundedNonEmpty(max: 4_000) { return "summary inválido." }
        if bodyMarkdown.isEmpty || Data(bodyMarkdown.utf8).count > PocketWikiSolutionIngestion.maximumMarkdownBytes { return "body_markdown inválido." }
        if let category, category.count > 200 { return "category inválida." }
        if tags.count > 50 || tags.contains(where: { $0.count > 80 }) { return "tags inválidas." }
        if !["R0", "R1", "R2", "R3"].contains(replicabilityLevel) { return "replicability_level inválido." }
        if sourceHashes.isEmpty || sourceHashes.contains(where: { !$0.isValid }) { return "source_hashes inválido." }
        if !["ai_enriched", "deterministic_only"].contains(publishMode) { return "publish_mode inválido." }
        return nil
    }

    var renderedMarkdown: String {
        let metadata: [(String, Any)] = [
            ("schema_version", schemaVersion),
            ("generator_version", generatorVersion),
            ("input_hash", inputHash),
            ("output_hash", outputHash),
            ("solution_id", solutionID),
            ("document_version", documentVersion),
            ("trace_or_context_id", traceOrContextID),
            ("title", title),
            ("summary", summary),
            ("category", category ?? NSNull()),
            ("tags", tags),
            ("replicability_level", replicabilityLevel),
            ("mvp5_candidate", mvp5Candidate),
            ("source_hashes", sourceHashes.map(\.object)),
            ("publish_mode", publishMode)
        ]
        let frontmatter = metadata.map { key, value in
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return "\(key): \(data.flatMap { String(data: $0, encoding: .utf8) } ?? "null")"
        }.joined(separator: "\n")
        let markdown = bodyMarkdown.hasSuffix("\n") ? bodyMarkdown : "\(bodyMarkdown)\n"
        return "---\n\(frontmatter)\n---\n\n\(markdown)"
    }
}

private struct PocketWikiSolutionSourceHash: Decodable {
    let path: String
    let artifactType: String
    let schemaVersion: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case path
        case artifactType = "artifact_type"
        case schemaVersion = "schema_version"
        case sha256
    }

    var isValid: Bool {
        !path.pocketTrimmed.isEmpty &&
            !artifactType.pocketTrimmed.isEmpty &&
            !schemaVersion.pocketTrimmed.isEmpty &&
            sha256.isSHA256
    }

    var object: [String: Any] {
        ["path": path, "artifact_type": artifactType, "schema_version": schemaVersion, "sha256": sha256]
    }
}

private struct PocketWikiIdempotencyRecord: Codable {
    let version: Int
    let idempotencyKey: String
    let requestHash: String
    let status: Int
    let etag: String
    let response: PocketWikiSolutionLogicalResponse
    let storedAt: String

    enum CodingKeys: String, CodingKey {
        case version, status, etag
        case response = "body"
        case idempotencyKey = "idempotency_key"
        case requestHash = "request_hash"
        case storedAt = "stored_at"
    }
}

private struct PocketWikiSolutionLogicalResponse: Codable {
    let remoteID: String
    let remoteRevision: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case remoteID = "remote_id"
        case remoteRevision = "remote_revision"
        case message
    }

    var object: [String: Any] {
        ["remote_id": remoteID, "remote_revision": remoteRevision, "message": message]
    }
}

private struct PocketWikiSolutionFailure: Error, @unchecked Sendable {
    let status: Int
    let body: [String: Any]
    let headers: [String: String]
}

private enum PocketWikiSolutionError: Error {
    case invalidJSON
    case unsafePath
    case verificationFailed
    case writeFailed
}

private extension String {
    var isSHA256: Bool {
        range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    var isSolutionID: Bool {
        range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    func isBoundedNonEmpty(max: Int) -> Bool {
        !pocketTrimmed.isEmpty && count <= max
    }
}

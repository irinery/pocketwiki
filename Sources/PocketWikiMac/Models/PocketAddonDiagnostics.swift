import CryptoKit
import Foundation

enum PocketAddonService: String, Codable, CaseIterable, Identifiable, Sendable {
    case middlewareAuth = "middleware_auth"
    case pocketKernel = "pocket_kernel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .middlewareAuth: "MiddlewareAuth"
        case .pocketKernel: "PocketKernel"
        }
    }

    var executableName: String {
        switch self {
        case .middlewareAuth: "middleware-codex-oauth"
        case .pocketKernel: "pocketkernel"
        }
    }

    var metadataDirectoryName: String {
        switch self {
        case .middlewareAuth: "MiddlewareAuth"
        case .pocketKernel: "PocketKernel"
        }
    }
}

struct PocketAddonBuildInfo: Codable, Equatable, Sendable {
    let schemaVersion: String
    let module: String
    let ref: String
    let architectures: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case module
        case ref
        case architectures
        case sha256
    }

    var shortRef: String {
        String(ref.prefix(8))
    }
}

struct PocketAddonReleaseBuilds: Codable, Equatable, Sendable {
    let middlewareAuth: PocketAddonBuildInfo?
    let pocketKernel: PocketAddonBuildInfo?

    private enum CodingKeys: String, CodingKey {
        case middlewareAuth = "middleware_auth"
        case pocketKernel = "pocket_kernel"
    }

    func build(for service: PocketAddonService) -> PocketAddonBuildInfo? {
        switch service {
        case .middlewareAuth: middlewareAuth
        case .pocketKernel: pocketKernel
        }
    }
}

struct PocketWikiBuildManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let releaseTag: String
    let appVersion: String
    let addons: PocketAddonReleaseBuilds?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case releaseTag = "release_tag"
        case appVersion = "app_version"
        case addons
    }
}

enum PocketAddonIntegrityStatus: Equatable, Sendable {
    case notChecked
    case externalUntracked
    case verified(PocketAddonBuildInfo)
    case failed(String)

    var title: String {
        switch self {
        case .notChecked: "integridade ainda não validada"
        case .externalUntracked: "binário externo sem manifesto do PocketWiki"
        case .verified(let build): "build \(build.shortRef) · SHA-256 verificado"
        case .failed(let reason): "integridade inválida: \(reason)"
        }
    }
}

struct PocketAddonRuntimeEvent: Equatable, Sendable {
    let service: PocketAddonService
    let level: PocketWikiServerLogEntry.Level
    let message: String
    let presentsAlert: Bool
}

struct PocketAddonAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let service: PocketAddonService
    let message: String

    var title: String {
        "Falha no add-on \(service.title)"
    }
}

enum PocketAddonBuildInspector {
    static func inspect(
        executableURL: URL,
        service: PocketAddonService,
        bundleURL: URL = Bundle.main.bundleURL,
        resourcesURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) throws -> PocketAddonIntegrityStatus {
        let bundled = executableURL.standardizedFileURL.path.hasPrefix(
            bundleURL.standardizedFileURL.path + "/"
        )
        guard bundled else { return .externalUntracked }
        guard let resourcesURL else {
            throw PocketAddonInspectionError.manifestMissing(service)
        }
        let manifestURL = resourcesURL
            .appendingPathComponent("Addons", isDirectory: true)
            .appendingPathComponent(service.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent("\(service.executableName).build.json")
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw PocketAddonInspectionError.manifestMissing(service)
        }
        let build = try JSONDecoder().decode(
            PocketAddonBuildInfo.self,
            from: Data(contentsOf: manifestURL)
        )
        let actualSHA = try sha256(of: executableURL)
        guard actualSHA.caseInsensitiveCompare(build.sha256) == .orderedSame else {
            throw PocketAddonInspectionError.checksumMismatch(service)
        }
        return .verified(build)
    }

    static func validateUpdatedApp(
        _ appURL: URL,
        expected: PocketAddonReleaseBuilds?
    ) throws -> PocketAddonReleaseBuilds {
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let helpersURL = appURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        var builds: [PocketAddonService: PocketAddonBuildInfo] = [:]

        for service in PocketAddonService.allCases {
            let executableURL = helpersURL.appendingPathComponent(service.executableName)
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw PocketAddonInspectionError.executableMissing(service)
            }
            let status = try inspect(
                executableURL: executableURL,
                service: service,
                bundleURL: appURL,
                resourcesURL: resourcesURL
            )
            guard case .verified(let build) = status else {
                throw PocketAddonInspectionError.manifestMissing(service)
            }
            if let expectedBuild = expected?.build(for: service), expectedBuild != build {
                throw PocketAddonInspectionError.releaseManifestMismatch(service)
            }
            builds[service] = build
        }

        return PocketAddonReleaseBuilds(
            middlewareAuth: builds[.middlewareAuth],
            pocketKernel: builds[.pocketKernel]
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum PocketAddonInspectionError: LocalizedError {
    case executableMissing(PocketAddonService)
    case manifestMissing(PocketAddonService)
    case checksumMismatch(PocketAddonService)
    case releaseManifestMismatch(PocketAddonService)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let service):
            "executável do \(service.title) ausente"
        case .manifestMissing(let service):
            "manifesto do \(service.title) ausente"
        case .checksumMismatch(let service):
            "SHA-256 do \(service.title) não corresponde ao manifesto"
        case .releaseManifestMismatch(let service):
            "manifesto interno do \(service.title) diverge do manifesto da release"
        }
    }
}

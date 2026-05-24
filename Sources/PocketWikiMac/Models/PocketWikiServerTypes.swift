import Foundation

enum PocketWikiServerMode: String, CaseIterable, Identifiable, Sendable {
    case localMac
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localMac: "Este Mac"
        case .external: "Servidor externo"
        }
    }
}

enum PocketWikiServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(PocketWikiRouteSnapshot)
    case remoteConnected(URL)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Desligado"
        case .starting: "Subindo"
        case .running: "Servidor ligado"
        case .remoteConnected: "Cliente remoto"
        case .failed: "Erro"
        }
    }

    var detail: String {
        switch self {
        case .stopped:
            "Nenhum servidor desktop ativo."
        case .starting:
            "Iniciando listener local..."
        case .running(let routes):
            routes.preferredURL ?? "Servidor ativo."
        case .remoteConnected(let url):
            "Conectado em \(url.absoluteString)"
        case .failed(let message):
            message
        }
    }
}

struct PocketWikiServerLogEntry: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let date: Date
    let level: Level
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), level: Level, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

enum WikiSourceMode: Equatable, Sendable {
    case none
    case localFolder(URL)
    case localServer(URL)
    case remoteServer(URL)

    var title: String {
        switch self {
        case .none: "sem fonte"
        case .localFolder: "pasta local"
        case .localServer: "servidor deste Mac"
        case .remoteServer: "servidor remoto"
        }
    }
}

struct PocketWikiRouteSnapshot: Codable, Equatable, Hashable, Sendable {
    let port: Int
    let bindHost: String
    let portless: Bool
    let local: [String]
    let mdns: [String]
    let lan: [String]
    let tailscale: [String]

    var preferredURL: String? {
        mdns.first ?? lan.first ?? tailscale.first ?? local.first
    }
}

struct PocketWikiServedSource: Sendable {
    let rootName: String
    let source: String
    let configured: Bool
    let readonly: Bool
    let available: Bool
    let status: String
    let files: [WikiFile]

    static func unavailable(rootName: String = "nenhuma wiki carregada", status: String = "missing") -> PocketWikiServedSource {
        PocketWikiServedSource(
            rootName: rootName,
            source: "desktop",
            configured: false,
            readonly: true,
            available: false,
            status: status,
            files: []
        )
    }
}

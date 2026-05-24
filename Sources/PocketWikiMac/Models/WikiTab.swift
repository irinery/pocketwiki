import Foundation

enum WikiTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case localAI
    case reader
    case excalidraw
    case map
    case health
    case timeline
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .localAI: "IA"
        case .reader: "Leitor"
        case .excalidraw: "Excalidraw"
        case .map: "Mapa"
        case .health: "Saude"
        case .timeline: "Tempo"
        case .server: "Servidor"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .localAI: "sparkles"
        case .reader: "doc.text"
        case .excalidraw: "scribble.variable"
        case .map: "point.3.connected.trianglepath.dotted"
        case .health: "waveform.path.ecg"
        case .timeline: "clock"
        case .server: "server.rack"
        }
    }

    var iconKind: PocketWikiIconKind {
        switch self {
        case .dashboard: .dashboard
        case .localAI: .ai
        case .reader: .reader
        case .excalidraw: .draw
        case .map: .map
        case .health: .health
        case .timeline: .timeline
        case .server: .server
        }
    }
}

struct WikiSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let pageID: String
    let title: String
    let path: String
    let reason: String
}

import Foundation

enum WikiTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case localAI
    case reader
    case excalidraw
    case health
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .localAI: "IA"
        case .reader: "Leitor"
        case .excalidraw: "Excalidraw"
        case .health: "Saude"
        case .timeline: "Tempo"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .localAI: "sparkles"
        case .reader: "doc.text"
        case .excalidraw: "scribble.variable"
        case .health: "waveform.path.ecg"
        case .timeline: "clock"
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

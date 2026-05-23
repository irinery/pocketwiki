import Foundation

struct WikiHealthIssue: Identifiable, Hashable, Sendable {
    enum Priority: String, CaseIterable, Sendable {
        case high
        case medium
        case low

        var label: String {
            switch self {
            case .high: "alta"
            case .medium: "media"
            case .low: "baixa"
            }
        }

        var sortOrder: Int {
            switch self {
            case .high: 0
            case .medium: 1
            case .low: 2
            }
        }
    }

    let id: String
    let priority: Priority
    let title: String
    let detail: String
    let pageIDs: [String]
}

struct WikiDashboardMetrics: Equatable, Sendable {
    let pages: Int
    let links: Int
    let drawings: Int
    let missingDestinations: Int
    let healthScore: Int
}

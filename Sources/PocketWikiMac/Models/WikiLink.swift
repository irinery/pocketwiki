import Foundation

struct WikiLink: Identifiable, Hashable, Sendable {
    let id: String
    let raw: String
    let targetRaw: String
    let target: String
    let heading: String
    let label: String

    init(raw: String, targetRaw: String, target: String, heading: String, label: String) {
        self.raw = raw
        self.targetRaw = targetRaw
        self.target = target
        self.heading = heading
        self.label = label
        self.id = "\(WikiTextParser.slugify(target))#\(WikiTextParser.slugify(heading))"
    }
}

struct WikiResolvedLink: Identifiable, Hashable, Sendable {
    let id: String
    let link: WikiLink
    let resolvedPageID: String

    init(link: WikiLink, resolvedPageID: String) {
        self.link = link
        self.resolvedPageID = resolvedPageID
        self.id = "\(link.id)->\(resolvedPageID)"
    }
}

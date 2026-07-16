import Foundation

enum PocketWikiReleaseChannel: Int, Sendable {
    case alpha = 0
    case stable = 1
}

struct PocketWikiReleaseVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let channel: PocketWikiReleaseChannel

    var numericString: String {
        "\(major).\(minor).\(patch)"
    }

    static func parse(tag: String) -> Self? {
        if tag.hasPrefix("alpha-") {
            return parse(version: String(tag.dropFirst("alpha-".count)), channel: .alpha)
        }
        return parse(version: tag, channel: .stable)
    }

    static func parse(version: String, channel: PocketWikiReleaseChannel) -> Self? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }
        return Self(major: major, minor: minor, patch: patch, channel: channel)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.channel.rawValue < rhs.channel.rawValue
    }
}

struct CanonicalRelease: Equatable, Sendable {
    let tag: String
    let version: PocketWikiReleaseVersion
    let assetName: String
    let assetURL: URL
    let pageURL: URL
}

enum CanonicalUpdateState: Equatable {
    case idle
    case checking
    case current
    case available(CanonicalRelease)
    case downloading(CanonicalRelease)
    case installing(CanonicalRelease)
    case failed(CanonicalRelease?, String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            true
        default:
            false
        }
    }
}

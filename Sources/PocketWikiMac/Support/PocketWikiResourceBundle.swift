import Foundation

enum PocketWikiResourceBundle {
    private static let bundleName = "PocketWikiMac_PocketWikiMac"

    static var bundle: Bundle? {
        candidateURLs.lazy.compactMap(Bundle.init(url:)).first
    }

    static var resourceURL: URL? {
        bundle?.resourceURL
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }

    private static var candidateURLs: [URL] {
        var urls: [URL] = []

        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            urls.append(URL(fileURLWithPath: override))
        }

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(bundleName + ".bundle", isDirectory: true))
        }

        urls.append(Bundle.main.bundleURL.appendingPathComponent(bundleName + ".bundle", isDirectory: true))
        return urls
    }
}

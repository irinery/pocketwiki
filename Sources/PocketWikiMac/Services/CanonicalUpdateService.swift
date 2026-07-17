import Foundation

enum CanonicalUpdateError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case invalidCurrentApp
    case invalidArchive(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Resposta inválida do GitHub."
        case .requestFailed(let status):
            "GitHub respondeu HTTP \(status)."
        case .invalidCurrentApp:
            "A atualização só pode ser instalada a partir do PocketWiki.app."
        case .invalidArchive(let message):
            "Arquivo de atualização inválido: \(message)"
        case .toolFailed(let message):
            message
        }
    }
}

actor CanonicalUpdateService {
    private static let bundleIdentifier = "com.irinery.PocketWikiMac"
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/irinery/pocketwiki/releases?per_page=30"
    )!

    func latestRelease(currentTag: String?, currentVersion: String?) async throws -> CanonicalRelease? {
        var request = URLRequest(url: Self.releasesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PocketWiki", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let githubReleases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        let parsedCurrentTag = currentTag.flatMap(PocketWikiReleaseVersion.parse(tag:))
        let stableOnly = parsedCurrentTag?.channel == .stable

        let releases = githubReleases.compactMap { release -> (GitHubRelease, PocketWikiReleaseVersion, GitHubAsset)? in
            guard !release.draft,
                  let version = PocketWikiReleaseVersion.parse(tag: release.tagName),
                  !stableOnly || version.channel == .stable else {
                return nil
            }
            guard let asset = release.assets.first(where: Self.isUpdateArchive) else {
                return nil
            }
            return (release, version, asset)
        }

        guard let selected = releases.max(by: { $0.1 < $1.1 }) else { return nil }
        if selected.0.tagName == currentTag { return nil }

        if let parsedCurrentTag {
            guard selected.1 > parsedCurrentTag else { return nil }
        }
        if parsedCurrentTag == nil,
           let currentVersion,
           let parsedCurrentVersion = PocketWikiReleaseVersion.parse(version: currentVersion, channel: .alpha),
           selected.1 < parsedCurrentVersion {
            return nil
        }

        let manifestName = String(selected.2.name.dropLast(".zip".count)) + ".build.json"
        let manifestAsset = selected.0.assets.first { $0.name == manifestName }
        let addonBuilds: PocketAddonReleaseBuilds?
        if let manifestAsset {
            addonBuilds = try await fetchBuildManifest(manifestAsset.browserDownloadURL).addons
        } else {
            addonBuilds = nil
        }
        return CanonicalRelease(
            tag: selected.0.tagName,
            version: selected.1,
            assetName: selected.2.name,
            assetURL: selected.2.browserDownloadURL,
            pageURL: selected.0.htmlURL,
            addonBuilds: addonBuilds
        )
    }

    func install(_ release: CanonicalRelease, replacing currentAppURL: URL) async throws {
        guard currentAppURL.pathExtension == "app" else {
            throw CanonicalUpdateError.invalidCurrentApp
        }

        let fileManager = FileManager.default
        let workDirectoryURL = fileManager.temporaryDirectory
            .appending(path: "PocketWiki-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        let archiveURL = workDirectoryURL.appending(path: release.assetName)
        let extractedURL = workDirectoryURL.appending(path: "extracted", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: release.assetURL)
            try validate(response)
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
            try runTool("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractedURL.path])

            let updatedAppURL = try findApp(in: extractedURL)
            try validate(
                updatedAppURL,
                expectedTag: release.tag,
                expectedVersion: release.version.numericString
            )
            _ = try PocketAddonBuildInspector.validateUpdatedApp(
                updatedAppURL,
                expected: release.addonBuilds
            )
            try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", updatedAppURL.path])
            try launchInstaller(
                updatedAppURL: updatedAppURL,
                currentAppURL: currentAppURL,
                workDirectoryURL: workDirectoryURL
            )
        } catch {
            try? fileManager.removeItem(at: workDirectoryURL)
            throw error
        }
    }

    private static func isUpdateArchive(_ asset: GitHubAsset) -> Bool {
        asset.name.hasPrefix("PocketWiki-")
            && asset.name.contains("-macOS-")
            && asset.name.hasSuffix(".zip")
    }

    private func fetchBuildManifest(_ url: URL) async throws -> PocketWikiBuildManifest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("PocketWiki", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(PocketWikiBuildManifest.self, from: data)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CanonicalUpdateError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CanonicalUpdateError.requestFailed(http.statusCode)
        }
    }

    private func findApp(in directoryURL: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CanonicalUpdateError.invalidArchive("ZIP vazio")
        }

        for case let url as URL in enumerator
            where url.pathExtension == "app" && url.lastPathComponent == "PocketWiki.app" {
            return url
        }
        throw CanonicalUpdateError.invalidArchive("PocketWiki.app não encontrado")
    }

    private func validate(_ appURL: URL, expectedTag: String, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == Self.bundleIdentifier else {
            throw CanonicalUpdateError.invalidArchive("bundle identifier inesperado")
        }
        let releaseTag = bundle.object(forInfoDictionaryKey: "PocketWikiReleaseTag") as? String
        guard releaseTag == expectedTag else {
            throw CanonicalUpdateError.invalidArchive("a versão interna não corresponde a \(expectedTag)")
        }
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard appVersion == expectedVersion else {
            throw CanonicalUpdateError.invalidArchive("CFBundleShortVersionString não corresponde a \(expectedVersion)")
        }
    }

    private func launchInstaller(
        updatedAppURL: URL,
        currentAppURL: URL,
        workDirectoryURL: URL
    ) throws {
        let scriptURL = workDirectoryURL.appending(path: "install-update.sh")
        let script = """
        #!/bin/sh
        set -eu

        src="$1"
        dst="$2"
        work="$3"
        pid="$4"
        backup="${dst}.previous"

        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
          kill -0 "$pid" >/dev/null 2>&1 || break
          sleep 0.2
        done

        rm -rf "$backup"
        if [ -d "$dst" ]; then
          mv "$dst" "$backup"
        fi

        if /usr/bin/ditto --noextattr --norsrc "$src" "$dst" &&
           /usr/bin/xattr -cr "$dst" &&
           /usr/bin/codesign --verify --deep --strict "$dst"; then
          rm -rf "$backup"
          /usr/bin/open "$dst"
          rm -rf "$work"
          exit 0
        fi

        rm -rf "$dst"
        if [ -d "$backup" ]; then
          mv "$backup" "$dst"
          /usr/bin/open "$dst"
        fi
        exit 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            updatedAppURL.path,
            currentAppURL.path,
            workDirectoryURL.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
        ]
        try process.run()
    }

    private func runTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CanonicalUpdateError.toolFailed(detail ?? "\(executable) falhou")
        }
    }
}

private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let htmlURL: URL
    let assets: [GitHubAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

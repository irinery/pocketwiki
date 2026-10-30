import Foundation

struct ExternalMiddlewareTokenStore {
    private struct Record: Codable {
        let baseURL: String
        let clientToken: String
    }

    private let rootOverride: URL?

    init(applicationSupportURL: URL? = nil) {
        rootOverride = applicationSupportURL
    }

    func load(baseURL: String) -> String? {
        guard let url = try? fileURL(create: false),
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.baseURL == canonical(baseURL),
              record.clientToken.count >= 32 else {
            return nil
        }
        return record.clientToken
    }

    func save(baseURL: String, clientToken: String) throws {
        let url = try fileURL(create: true)
        let record = Record(baseURL: canonical(baseURL), clientToken: clientToken)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fileURL(create: Bool) throws -> URL {
        let support = try rootOverride ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let directory = support.appendingPathComponent("PocketWiki", isDirectory: true)
            .appendingPathComponent("MiddlewareAuth", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory.appendingPathComponent("external-client-token.json")
    }

    private func canonical(_ baseURL: String) -> String {
        baseURL.pocketTrimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

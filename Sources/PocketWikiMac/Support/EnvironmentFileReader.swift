import Foundation

enum EnvironmentFileReader {
    static let maximumSize = 1_048_576

    static func firstReadable(
        in candidates: [URL],
        fileManager: FileManager = .default
    ) -> (url: URL, contents: String)? {
        for url in candidates {
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.intValue,
                size <= maximumSize,
                let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                data.count <= maximumSize,
                let contents = String(data: data, encoding: .utf8)
            else {
                continue
            }

            return (url, contents)
        }

        return nil
    }
}

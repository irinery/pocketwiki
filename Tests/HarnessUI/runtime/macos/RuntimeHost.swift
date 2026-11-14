import AppKit
import SwiftUI

@main
struct RuntimeHostApp: App {
    @StateObject private var session: RuntimeUISession
    init() {
        guard let line = readLine(), let data = line.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let urlText = config["baseURL"], let url = URL(string: urlText), let bearer = config["bearer"],
              let environmentText = config["environmentID"], let environment = UUID(uuidString: environmentText),
              let threadText = config["threadID"], let thread = UUID(uuidString: threadText),
              let schemaPath = config["schemaPath"], let schemaData = try? Data(contentsOf: URL(fileURLWithPath: schemaPath)),
              let hash = config["schemaSHA256"], let transport = try? RuntimeTransport(baseURL: url, bearer: bearer),
              let session = try? RuntimeUISession(transport: transport, environmentID: environment, threadID: thread, schemaHash: hash, schemaData: schemaData) else { fatalError("Invalid runtime host configuration") }
        _session = StateObject(wrappedValue: session)
    }
    var body: some Scene {
        WindowGroup("PocketWiki runtime test host") { RuntimePanel(session: session).frame(minWidth: 650, minHeight: 620) }
    }
}

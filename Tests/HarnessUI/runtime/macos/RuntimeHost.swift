import AppKit
import SwiftUI

@main
struct RuntimeHostApp: App {
    @StateObject private var session: RuntimeUISession
    init() {
        let data: Data?
        if let path = ProcessInfo.processInfo.environment["NH_RUNTIME_CONFIG_PATH"] { data = try? Data(contentsOf: URL(fileURLWithPath: path)) }
        else { data = readLine()?.data(using: .utf8) }
        guard let data,
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let urlText = config["baseURL"], let url = URL(string: urlText), let bearer = config["bearer"],
              let environmentText = config["environmentID"], let environment = UUID(uuidString: environmentText),
              let threadText = config["threadID"], let thread = UUID(uuidString: threadText),
              let schemaPath = config["schemaPath"], let schemaData = try? Data(contentsOf: URL(fileURLWithPath: schemaPath)),
              let hash = config["schemaSHA256"], let transport = try? RuntimeTransport(baseURL: url, bearer: bearer),
              let session = try? RuntimeUISession(transport: transport, environmentID: environment, threadID: thread, schemaHash: hash, schemaData: schemaData) else { fatalError("Invalid runtime host configuration") }
        if config["observeFrames"] == "1" {
            session.onFrame = { seq, cursor in
                DistributedNotificationCenter.default().post(name: Notification.Name("com.pocketwiki.RuntimeUIFrame"), object: nil, userInfo: ["seq": seq, "cursor": cursor])
            }
        }
        _session = StateObject(wrappedValue: session)
    }
    var body: some Scene {
        WindowGroup("PocketWiki runtime test host") { RuntimePanel(session: session).frame(minWidth: 650, minHeight: 620) }
    }
}

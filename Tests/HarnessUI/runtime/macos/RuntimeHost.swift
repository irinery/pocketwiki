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
              let hash = config["schemaSHA256"], let transport = try? RuntimeTransport(baseURL: url, bearer: bearer) else { fatalError("Invalid runtime host configuration") }
        guard let rawIDs = config["commandIDs"], !rawIDs.isEmpty else { fatalError("IDs de fixture ausentes") }
        let parts = rawIDs.split(separator: ",", omittingEmptySubsequences: false)
        let commandIDs = parts.compactMap { UUID(uuidString: String($0)) }
        guard commandIDs.count == parts.count, Set(commandIDs).count == commandIDs.count else { fatalError("IDs de fixture inválidos") }
        var nextCommand = 0
        guard let session = try? RuntimeUISession(transport: transport, environmentID: environment, threadID: thread, schemaHash: hash, schemaData: schemaData, newCommandID: {
            precondition(nextCommand < commandIDs.count, "IDs de fixture esgotados")
            defer { nextCommand += 1 }
            return commandIDs[nextCommand]
        }) else { fatalError("Invalid runtime host configuration") }
        if config["observeFrames"] == "1" {
            if let nonce = config["replayNonce"], !nonce.isEmpty {
                session.replayNextFrameForFixture = true
                session.onProjectionFrame = { boundary, snapshotID, seq, eventID, beforeCursor, afterCursor, before, after, event in
                    DistributedNotificationCenter.default().post(name: Notification.Name("com.pocketwiki.RuntimeProjectionFrame"), object: nil, userInfo: ["nonce": nonce, "boundary": boundary, "snapshot_id": snapshotID, "seq": seq, "event_id": eventID, "event": event, "before_cursor": beforeCursor, "after_cursor": afterCursor, "before_state": before, "after_state": after])
                }
            }
            session.onFrame = { seq, cursor, receiptCount in
                DistributedNotificationCenter.default().post(name: Notification.Name("com.pocketwiki.RuntimeUIFrame"), object: nil, userInfo: ["seq": seq, "cursor": cursor, "receiptCount": receiptCount])
            }
        }
        _session = StateObject(wrappedValue: session)
    }
    var body: some Scene {
        WindowGroup("PocketWiki runtime test host") { RuntimePanel(session: session).frame(minWidth: 650, minHeight: 620).accessibilityElement(children: .contain).accessibilityIdentifier("runtime-test-slot") }
    }
}

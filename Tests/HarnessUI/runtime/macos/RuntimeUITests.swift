import XCTest

final class RuntimeUITests: XCTestCase {
    private var recordedFailure = false
    override func record(_ issue: XCTIssue) {
        recordedFailure = true
        super.record(issue)
    }
    func testRuntimePanel() throws {
        let app = XCUIApplication(), env = ProcessInfo.processInfo.environment
        addTeardownBlock {
            guard self.recordedFailure else { return }
            let slot = app.descendants(matching: .any).matching(identifier: "runtime-test-slot").firstMatch
            guard slot.exists else { print("runtime failure screenshot unavailable: fixture slot absent"); return }
            let attachment = XCTAttachment(screenshot: slot.screenshot())
            attachment.name = "runtime-failure-slot"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        guard let config = env["NH_RUNTIME_CONFIG_PATH"], !config.isEmpty else { XCTFail("NH_RUNTIME_CONFIG_PATH ausente"); return }
        let configuration = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config))) as? [String: String])
        let boundary = Int(configuration["replayBoundary"] ?? "")
        let replay = env["NH_RUNTIME_SCENARIO"] == "replay" && env["NH_RUNTIME_TEST_FORCE_FAILURE"] != "1"
        var frames: [(Int, Int, Int)] = []
        var projectionFrames: [[String: Any]] = []
        var observedBoundary: Int?
        let projectionObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.pocketwiki.RuntimeProjectionFrame"), object: nil, queue: .main) { note in
            guard let expectedNonce = configuration["replayNonce"], !expectedNonce.isEmpty, note.userInfo?["nonce"] as? String == expectedNonce,
                  let boundary = note.userInfo?["boundary"] as? Int, let snapshotID = note.userInfo?["snapshot_id"] as? String, let seq = note.userInfo?["seq"] as? Int,
                  let eventID = note.userInfo?["event_id"] as? String, let eventData = note.userInfo?["event"] as? Data,
                  let event = try? JSONSerialization.jsonObject(with: eventData),
                  let before = note.userInfo?["before_state"] as? Data, let after = note.userInfo?["after_state"] as? Data,
                  let beforeCursor = note.userInfo?["before_cursor"] as? Int, let afterCursor = note.userInfo?["after_cursor"] as? Int,
                  let beforeState = try? JSONSerialization.jsonObject(with: before), let afterState = try? JSONSerialization.jsonObject(with: after) else { return }
            if observedBoundary == nil { observedBoundary = boundary }
            guard observedBoundary == boundary else { return }
            projectionFrames.append(["snapshot_id": snapshotID, "seq": seq, "event_id": eventID, "event": event, "before_cursor": beforeCursor, "after_cursor": afterCursor, "before_state": beforeState, "after_state": afterState])
        }
        defer { DistributedNotificationCenter.default().removeObserver(projectionObserver) }
        let replayed = replay ? expectation(description: "replay 8/9") : nil
        let advanced = replay ? expectation(description: "eventos 10/11/12") : nil
        let observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.pocketwiki.RuntimeUIFrame"), object: nil, queue: .main) { note in
            guard let seq = note.userInfo?["seq"] as? Int, let cursor = note.userInfo?["cursor"] as? Int, let count = note.userInfo?["receiptCount"] as? Int else { return }
            frames.append((seq, cursor, count)); if frames.count == 2 { replayed?.fulfill() }; if frames.count == 5 { advanced?.fulfill() }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        app.launchEnvironment["NH_RUNTIME_CONFIG_PATH"] = config; app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]; app.launch()
        if env["NH_RUNTIME_TEST_FORCE_FAILURE"] == "1" {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "runtime-test-slot").firstMatch.waitForExistence(timeout: 10))
            XCTFail("forced runtime fixture failure"); return
        }
        XCTAssertTrue(app.staticTexts["Runtime conectado"].waitForExistence(timeout: 30))
        let submit = app.buttons["runtime-submit"]
        func receiptIsVisible(_ id: String) -> Bool { app.descendants(matching: .any).matching(identifier: "runtime-receipt-" + id).firstMatch.exists }
        if replay { wait(for: [replayed!], timeout: 30); let b = try XCTUnwrap(boundary); XCTAssertEqual(frames.prefix(2).map(\.0), [b - 1, b]); XCTAssertEqual(frames.prefix(2).map(\.1), [b, b]); XCTAssertEqual(frames.prefix(2).map(\.2), [1, 1]); XCTAssertTrue(app.staticTexts["1 recibo"].exists); XCTAssertTrue(receiptIsVisible(try XCTUnwrap(configuration["seedCommandID"]))) }
        switch env["NH_RUNTIME_SCENARIO"] {
        case "accepted", "incompatible", "replay":
            let input = app.textFields["Texto do comando durável"]
            XCTAssertTrue(input.waitForExistence(timeout: 10)); app.activate(); input.click(); input.typeText("efeito real macOS")
            XCTAssertTrue(submit.waitForExistence(timeout: 10)); XCTAssertTrue(submit.isEnabled); submit.click()
            if env["NH_RUNTIME_SCENARIO"] == "accepted" {
                XCTAssertTrue(app.staticTexts["Aceito"].waitForExistence(timeout: 30)); XCTAssertFalse(app.staticTexts["Concluído"].exists); XCTAssertTrue(receiptIsVisible(try XCTUnwrap(configuration["commandID"])))
            } else if replay {
                wait(for: [advanced!], timeout: 30)
                if let nonce = configuration["replayNonce"], let proofPath = configuration["replayProofPath"], !nonce.isEmpty {
                    let boundary = try XCTUnwrap(observedBoundary)
                    XCTAssertEqual(projectionFrames.prefix(4).compactMap { $0["seq"] as? Int }, [boundary - 1, boundary, boundary + 1, boundary + 1])
                    let proof: [String: Any] = ["version": 1, "surface": "macos", "level": "integration", "nonce": nonce, "boundary": boundary, "frames": Array(projectionFrames.prefix(4))]
                    try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]).write(to: URL(fileURLWithPath: proofPath), options: .atomic)
                }
                let b = try XCTUnwrap(boundary)
                if configuration["replayNonce"]?.isEmpty == false {
                    XCTAssertEqual(frames.prefix(5).map(\.0), [b - 1, b, b + 1, b + 1, b + 2]); XCTAssertEqual(frames.prefix(5).map(\.1), [b, b, b + 1, b + 1, b + 2]); XCTAssertEqual(frames.prefix(5).map(\.2), [1, 1, 1, 1, 2])
                } else {
                    XCTAssertEqual(frames.prefix(5).map(\.0), [b - 1, b, b + 1, b + 2, b + 3]); XCTAssertEqual(frames.prefix(5).map(\.1), [b, b, b + 1, b + 2, b + 3]); XCTAssertEqual(frames.prefix(5).map(\.2), [1, 1, 1, 2, 2])
                }
                XCTAssertTrue(app.staticTexts["2 recibos"].waitForExistence(timeout: 10)); XCTAssertTrue(receiptIsVisible(try XCTUnwrap(configuration["seedCommandID"]))); XCTAssertTrue(receiptIsVisible(try XCTUnwrap(configuration["commandID"])))
            } else {
                XCTAssertTrue(app.staticTexts["ERR_INCOMPATIBLE"].waitForExistence(timeout: 30)); XCTAssertTrue(app.staticTexts["Revisão 0 · evento 0"].exists)
            }
        default: break
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "runtime-fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

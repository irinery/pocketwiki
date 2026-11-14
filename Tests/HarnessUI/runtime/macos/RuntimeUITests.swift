import XCTest

final class RuntimeUITests: XCTestCase {
    func testRuntimePanel() throws {
        let app = XCUIApplication(), env = ProcessInfo.processInfo.environment
        guard let config = env["NH_RUNTIME_CONFIG_PATH"], !config.isEmpty else { XCTFail("NH_RUNTIME_CONFIG_PATH ausente"); return }
        let replay = env["NH_RUNTIME_SCENARIO"] == "replay"
        var frames: [(Int, Int)] = []
        let replayed = replay ? expectation(description: "replay 8/9") : nil
        let advanced = replay ? expectation(description: "eventos 10/11/12") : nil
        let observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.pocketwiki.RuntimeUIFrame"), object: nil, queue: .main) { note in
            guard let seq = note.userInfo?["seq"] as? Int, let cursor = note.userInfo?["cursor"] as? Int else { return }
            frames.append((seq, cursor)); if frames.count == 2 { replayed?.fulfill() }; if frames.count == 5 { advanced?.fulfill() }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        app.launchEnvironment["NH_RUNTIME_CONFIG_PATH"] = config; app.launch()
        XCTAssertTrue(app.staticTexts["Runtime conectado"].waitForExistence(timeout: 30))
        let submit = app.buttons["runtime-submit"]
        if replay { wait(for: [replayed!], timeout: 30); XCTAssertEqual(frames.prefix(2).map(\.0), [8, 9]); XCTAssertEqual(frames.prefix(2).map(\.1), [9, 9]) }
        switch env["NH_RUNTIME_SCENARIO"] {
        case "accepted", "incompatible", "replay":
            let input = app.textFields["Texto do comando durável"]
            XCTAssertTrue(input.waitForExistence(timeout: 10)); app.activate(); input.click(); input.typeText("efeito real macOS")
            XCTAssertTrue(submit.waitForExistence(timeout: 10)); XCTAssertTrue(submit.isEnabled); submit.click()
            if env["NH_RUNTIME_SCENARIO"] == "accepted" {
                XCTAssertTrue(app.staticTexts["Aceito"].waitForExistence(timeout: 30)); XCTAssertFalse(app.staticTexts["Concluído"].exists)
            } else if replay {
                wait(for: [advanced!], timeout: 30); XCTAssertEqual(frames.prefix(5).map(\.0), [8, 9, 10, 11, 12]); XCTAssertEqual(frames.prefix(5).map(\.1), [9, 9, 10, 11, 12])
            } else {
                XCTAssertTrue(app.staticTexts["ERR_INCOMPATIBLE"].waitForExistence(timeout: 30)); XCTAssertTrue(app.staticTexts["Revisão 0 · evento 0"].exists)
            }
        default: break
        }
    }
}

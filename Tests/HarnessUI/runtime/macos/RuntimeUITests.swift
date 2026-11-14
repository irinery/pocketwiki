import XCTest

final class RuntimeUITests: XCTestCase {
    func testRuntimePanelConnects() throws {
        let app = XCUIApplication()
        guard let config = ProcessInfo.processInfo.environment["NH_RUNTIME_CONFIG_PATH"], !config.isEmpty else { XCTFail("NH_RUNTIME_CONFIG_PATH ausente"); return }
        app.launchEnvironment["NH_RUNTIME_CONFIG_PATH"] = config
        app.launch()
        XCTAssertTrue(app.staticTexts["Runtime conectado"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["runtime-submit"].exists)
    }
}

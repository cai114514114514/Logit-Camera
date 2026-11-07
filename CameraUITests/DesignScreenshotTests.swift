import XCTest

/// 设计审阅用：逐个演示场景启动 App 并保存截图。演示模式不发网络请求、不运行调度器。
final class DesignScreenshotTests: XCTestCase {
    private let scenarios = ["idle", "scouting", "composing", "capturing", "cooldown", "picking", "landscape", "manual", "error", "offline"]

    @MainActor
    func testCaptureEveryScenario() {
        continueAfterFailure = true
        for scenario in scenarios {
            let app = XCUIApplication()
            app.launchArguments = ["-LogitDemo", scenario]
            app.launch()
            XCTAssertTrue(app.buttons["camera.ai"].waitForExistence(timeout: 15), scenario)
            Thread.sleep(forTimeInterval: 2.5)
            attach(app, name: scenario)

            switch scenario {
            case "scouting":
                // 扫描线每 2 秒一次、持续 0.9 秒：连拍几张以捕捉到它。
                for index in 0..<6 {
                    attach(app, name: "scan-\(index)")
                    Thread.sleep(forTimeInterval: 0.15)
                }
            case "composing":
                // 演示模式不得启动真实循环：轮次保持不变。
                let agent = app.descendants(matching: .any)["camera.agent"].firstMatch
                XCTAssertTrue(agent.waitForExistence(timeout: 5))
                let before = agent.value as? String
                Thread.sleep(forTimeInterval: 6)
                XCTAssertEqual(agent.value as? String, before, "demo must not run real agent rounds")
            case "capturing":
                XCTAssertTrue(app.buttons["camera.shutter"].exists)
                app.descendants(matching: .any)["camera.agent"].firstMatch.tap()
                XCTAssertTrue(app.switches["camera.autoCapture"].waitForExistence(timeout: 5))
                attach(app, name: "capturing-detail")
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.8)
                attach(app, name: "capturing-detail-critique")
            case "idle":
                app.buttons["camera.aiSettings"].tap()
                Thread.sleep(forTimeInterval: 1)
                attach(app, name: "idle-settings")
            default:
                break
            }
            app.terminate()
        }
    }

    /// 真机感知检查：只运行感知层，读取诊断叠层（快档耗时与测量）。
    @MainActor
    func testPerceptionProbe() {
        let app = XCUIApplication()
        app.launchArguments = ["-LogitPerceptionOnly"]
        app.launch()
        let diagnostics = app.staticTexts["camera.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 8)
        attach(app, name: "perception")
        let label = diagnostics.label
        let attachment = XCTAttachment(string: label)
        attachment.name = "perception-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(label.contains("快档"), label)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

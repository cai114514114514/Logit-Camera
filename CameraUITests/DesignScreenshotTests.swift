import XCTest

/// 设计审阅用：逐个演示场景启动 App 并保存截图。演示模式不发网络请求。
final class DesignScreenshotTests: XCTestCase {
    private let scenarios = ["idle", "observing", "adjusted", "ready", "countdown", "manual", "error"]

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
            case "observing":
                // 演示模式不得启动真实 Agent：10 秒内轮次不变。
                let agent = app.descendants(matching: .any)["camera.agent"].firstMatch
                XCTAssertTrue(agent.waitForExistence(timeout: 5))
                let before = agent.value as? String
                Thread.sleep(forTimeInterval: 10)
                XCTAssertEqual(agent.value as? String, before, "demo must not run real agent rounds")
                attach(app, name: "observing-later")
            case "ready":
                app.descendants(matching: .any)["camera.agent"].firstMatch.tap()
                XCTAssertTrue(app.switches["camera.autoCapture"].waitForExistence(timeout: 5))
                attach(app, name: "ready-detail-sheet")
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

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// 真机交互：双指缩放与点按对焦（SwiftUI 手势与 UIKit 点按共存），使用演示模式，不发网络请求。
final class InteractionTests: XCTestCase {
    /// Review Focus：就绪时双指缩放 → 接管变焦、AI 停止、不再就绪。
    @MainActor
    func testPinchWhileArmedTakesOverZoom() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitDemo", "armed"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.disarm"].waitForExistence(timeout: 15))

        app.descendants(matching: .any)["camera.preview"].firstMatch.pinch(withScale: 2, velocity: 2)

        let notice = app.descendants(matching: .any)["camera.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertTrue(notice.label.contains("变焦"), notice.label)
        XCTAssertTrue(app.buttons["camera.disarm"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
        XCTAssertEqual(app.buttons["camera.ai"].value as? String, "已关闭")
    }

    /// 点按对焦不停止 AI。
    @MainActor
    func testTapToFocusKeepsAIRunning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitDemo", "tracking"]
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        XCTAssertEqual(ai.value as? String, "已开启")

        app.descendants(matching: .any)["camera.preview"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        XCTAssertEqual(ai.value as? String, "已开启")
        XCTAssertFalse(app.descendants(matching: .any)["camera.notice"].exists)
    }
}

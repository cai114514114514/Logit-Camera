import XCTest

/// 真机交互：双指缩放与点按对焦（SwiftUI 手势与 UIKit 点按共存），使用演示模式，不发网络请求。
final class InteractionTests: XCTestCase {
    /// 取景时双指缩放 → 接管变焦、AI 停止。
    @MainActor
    func testPinchWhileComposingTakesOverZoom() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitDemo", "composing"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 15))

        app.descendants(matching: .any)["camera.preview"].firstMatch.pinch(withScale: 2, velocity: 2)

        let notice = app.descendants(matching: .any)["camera.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        XCTAssertTrue(notice.label.contains("变焦"), notice.label)
        XCTAssertTrue(app.buttons["camera.shutter"].exists)
        XCTAssertEqual(app.buttons["camera.ai"].value as? String, "已关闭")
    }

    /// 点按对焦不停止 AI。
    @MainActor
    func testTapToFocusKeepsAIRunning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitDemo", "composing"]
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        XCTAssertEqual(ai.value as? String, "已开启")

        app.descendants(matching: .any)["camera.preview"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        XCTAssertEqual(ai.value as? String, "已开启")
        XCTAssertFalse(app.descendants(matching: .any)["camera.notice"].exists)
    }

    /// 规格 §2：AI 开启时按快门一定出片（离线导演，不花 API 额度），不会被「相机正在调整」拒绝。
    @MainActor
    func testShutterAlwaysCapturesWithAIOn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitOfflineDirector"]
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        ai.tap()
        XCTAssertEqual(ai.value as? String, "已开启")
        Thread.sleep(forTimeInterval: 2)
        // 关闭自动拍摄，确保这张是手动按下的。
        app.descendants(matching: .any)["camera.agent"].firstMatch.tap()
        let auto = app.switches["camera.autoCapture"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        if (auto.value as? String) == "1" { auto.switches.firstMatch.tap() }
        app.buttons["完成"].firstMatch.tap()
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        let photo = app.buttons["camera.photo"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 10)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "相机正在调整")).firstMatch.exists)
    }

    /// 规格 §2：静止场景里 AI 自己拍下一组，详情里能看到连拍备选。
    @MainActor
    func testAutoCaptureInStaticScene() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitOfflineDirector"]
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        ai.tap()
        let photo = app.buttons["camera.photo"]
        // AI 应在静止场景中自动拍摄：缩略图按钮在第一张照片出现后才可用。
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        photo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["photo.alternates"].firstMatch.waitForExistence(timeout: 10))
    }
}

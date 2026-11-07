import XCTest

/// 真机交互：双指缩放与点按对焦（SwiftUI 手势与 UIKit 点按共存），使用演示模式，不发网络请求。
final class InteractionTests: XCTestCase {
    /// 取景时双指缩放 → 接管变焦、AI 停止。
    @MainActor
    func testPinchWhileComposingTakesOverZoom() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitDemo", "composing"]
        app.launchArguments.append("-LogitNoLibrary")
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
        app.launchArguments.append("-LogitNoLibrary")
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
        app.launchArguments.append("-LogitNoLibrary")
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
        if (auto.value as? String) == "1" { auto.tap() }
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
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        ai.tap()
        let photo = app.buttons["camera.photo"]
        // AI 应在静止场景中自动拍摄：缩略图按钮在第一张照片出现后才可用。
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        photo.tap()
        // 只保留最好的一张：详情里不再有连拍备选。
        XCTAssertTrue(app.staticTexts["photo.dimensions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["photo.alternates"].firstMatch.exists)
    }

    /// C1：取景实时调色，自定义着色器（暗角）编译或安全跳过后都能正常出片。
    @MainActor
    func testCustomShaderLookStillCaptures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitLook", "vignette"]
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "look-vignette-preview"
        preview.lifetime = .keepAlways
        add(preview)
        shutter.tap()
        let photo = app.buttons["camera.photo"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 15)
        photo.tap()
        XCTAssertTrue(app.staticTexts["photo.dimensions"].waitForExistence(timeout: 10))
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "look-vignette-photo"
        detail.lifetime = .keepAlways
        add(detail)
    }

    /// C1：暖调配方在取景中实时生效（截图检查）。
    @MainActor
    func testWarmLookPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-LogitLook", "warm"]
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "look-warm-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func attachShot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// C2：滤镜条打开、选中「胶片暖」，拍照正常出片。
    @MainActor
    func testPresetLookCaptures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitPreset", "胶片暖"]
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["look.strip"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.sliders["look.strength"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.5)
        attachShot(app, "looks-strip-film")
        app.buttons["camera.shutter"].tap()
        let photo = app.buttons["camera.photo"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 15)
    }

    /// C2：调整面板能打开，滑杆可见。
    @MainActor
    func testAdjustSheetOpens() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitPreset", "通透"]
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        let adjust = app.buttons["look.adjust"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 15))
        adjust.tap()
        XCTAssertTrue(app.staticTexts["曝光"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        attachShot(app, "looks-adjust")
    }

    /// C2：照片详情里换滤镜并出现「另存为新照片」。
    @MainActor
    func testRelookInPhotoDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        shutter.tap()
        let photo = app.buttons["camera.photo"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: photo)], timeout: 15)
        photo.tap()
        let mono = app.buttons["detail.look.黑白"]
        XCTAssertTrue(mono.waitForExistence(timeout: 10))
        mono.tap()
        XCTAssertTrue(app.buttons["detail.saveLook"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        attachShot(app, "looks-relook-mono")
    }

    /// C3：AI 开启（离线导演）时修正层生效，详情里可以关掉智能修正。
    @MainActor
    func testSmartCorrectionToggle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LogitOfflineDirector"]
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        let ai = app.buttons["camera.ai"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15))
        ai.tap()
        Thread.sleep(forTimeInterval: 3)
        attachShot(app, "correction-on")
        app.descendants(matching: .any)["camera.agent"].firstMatch.tap()
        let toggle = app.switches["camera.smartCorrection"]
        if !toggle.waitForExistence(timeout: 3) { app.descendants(matching: .any)["camera.agent"].firstMatch.tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        attachShot(app, "correction-detail")
        XCTAssertEqual(toggle.value as? String, "1")
        // 点开关本体（右侧），不点左侧说明文字。
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let off = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        wait(for: [off], timeout: 3)
        attachShot(app, "correction-off")
    }
}

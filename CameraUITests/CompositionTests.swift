import XCTest

final class CompositionTests: XCTestCase {
    @MainActor
    func testPreviewRatiosMatchTheirSelectedFrames() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["camera.ratio"].waitForExistence(timeout: 15))
        let preview = app.descendants(matching: .any)["camera.preview"].firstMatch
        for (label, ratio) in [("3:4", 0.75), ("9:16", 0.5625), ("1:1", 1.0)] {
            if app.buttons["camera.ratio"].value as? String != label {
                app.buttons["camera.ratio"].tap()
                XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5))
                app.buttons[label].tap()
                XCTAssertTrue(app.buttons[label].waitForNonExistence(timeout: 5))
            }
            let matches = NSPredicate { _, _ in
                preview.exists && abs(preview.frame.width / preview.frame.height - ratio) < 0.01
            }
            let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: app)], timeout: 5)
            XCTAssertEqual(result, .completed, "Preview frame: \(preview.frame). " + app.debugDescription)
            XCTAssertGreaterThanOrEqual(preview.frame.width, app.frame.width * 0.95)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Full-width square preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAgentAutomaticallyCapturesOnePhotoWhenReady() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["camera.ai"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        expectation(for: NSPredicate { _, _ in button.isEnabled }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        button.tap()
        let photo = app.buttons["camera.photo"]
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in photo.isEnabled }, object: app)
        let outcome = XCTWaiter().wait(for: [captured], timeout: 85)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Automatic capture result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(outcome, .completed, app.debugDescription)
        // 「再拍一张」位于 AI 详情面板中。
        app.descendants(matching: .any)["camera.agent"].firstMatch.tap()
        XCTAssertTrue(app.buttons["camera.rearm"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        if button.isEnabled && button.isSelected { button.tap() }
        photo.tap()
        XCTAssertTrue(app.staticTexts["photo.dimensions"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDeepSeekRunsMultipleRoundsAndCanBeStopped() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["camera.ai"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        expectation(for: NSPredicate { _, _ in button.isEnabled }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        button.tap()
        // 自动拍摄开关位于 AI 详情面板中。
        let status = app.descendants(matching: .any)["camera.agent"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.tap()
        let autoCapture = app.switches["camera.autoCapture"]
        if autoCapture.waitForExistence(timeout: 5), autoCapture.value as? String == "1" { autoCapture.tap() }
        app.buttons["完成"].tap()
        let readout = app.descendants(matching: .any)["camera.agent"].firstMatch
        let completed = NSPredicate { _, _ in
            guard readout.exists else { return false }
            let count = (readout.value as? String ?? "").filter { $0.isNumber }
            return (Int(count) ?? 0) >= 2
        }
        let outcome = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: completed, object: app)], timeout: 65)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "DeepSeek live agent loop"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(outcome, .completed, app.debugDescription)
        button.tap()
        XCTAssertFalse(button.isSelected)
        XCTAssertEqual(button.value as? String, "已关闭")
        app.buttons["camera.controls"].tap()
        XCTAssertTrue(app.buttons["aperture.4.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["aperture.4.0"].isEnabled)
    }
}

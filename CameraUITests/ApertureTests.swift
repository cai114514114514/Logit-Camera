import XCTest

final class ApertureTests: XCTestCase {
    @MainActor
    func testMainCameraPhysicallyChangesAperture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("-LogitNoLibrary")
        app.launch()
        XCTAssertTrue(app.buttons["camera.controls"].waitForExistence(timeout: 15))
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)["NotificationShortLookView"].firstMatch
        if banner.exists { XCTAssertTrue(banner.waitForNonExistence(timeout: 15)) }
        app.buttons["camera.controls"].tap()
        let narrow = app.buttons["aperture.4.0"]
        XCTAssertTrue(narrow.waitForExistence(timeout: 15), "Run on an unlocked iPhone 18 Pro Max with camera access allowed.")
        XCTAssertTrue(narrow.isEnabled)

        narrow.tap()
        assertActualAperture(4, in: app)
        attachScreenshot("Physical aperture f4", app: app)

        let wide = app.buttons["aperture.1.48"]
        XCTAssertTrue(wide.isEnabled)
        wide.tap()
        assertActualAperture(1.48, in: app)
        attachScreenshot("Physical aperture f1.48", app: app)

        app.buttons["aperture.auto"].tap()
        let automatic = NSPredicate { _, _ in app.buttons["aperture.auto"].isSelected }
        expectation(for: automatic, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func assertActualAperture(_ expected: Float, in app: XCUIApplication) {
        // This element displays AVCaptureDevice.lensAperture, not the request.
        // Hardware readback may differ slightly from the nominal f-stop.
        let actual = app.staticTexts["camera.aperture"].firstMatch
        let matches = NSPredicate { _, _ in
            guard actual.exists,
                  let value = Float(actual.label.replacingOccurrences(of: "ƒ/", with: "")) else { return false }
            return abs(value - expected) < 0.08
        }
        expectation(for: matches, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
    }

    @MainActor
    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

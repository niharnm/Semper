import XCTest

final class ShellModeUITests: XCTestCase {
    @MainActor
    func testColdShellNavigationSearchAndModuleMetadata() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--shell-ui-testing"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Semper Shell UI Tests"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["shell-ui-test-host"].exists)
        XCTAssertTrue(window.staticTexts["Home"].exists)
        XCTAssertTrue(window.staticTexts["Modules"].exists)
        XCTAssertTrue(window.staticTexts["Sound"].firstMatch.exists)

        let search = window.textFields["Search Semper actions"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        let homeScreenshot = XCTAttachment(screenshot: window.screenshot())
        homeScreenshot.name = "Semper Shell Home"
        homeScreenshot.lifetime = .keepAlways
        add(homeScreenshot)
        search.click()
        search.typeText("silence")
        XCTAssertTrue(window.buttons["Mute current output"].waitForExistence(timeout: 3))
        XCTAssertFalse(window.buttons["Unmute current output"].exists)

        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-matching-shell-action")
        XCTAssertTrue(
            window.staticTexts["No matching actions. Add a module to make its actions available."]
                .waitForExistence(timeout: 3))

        window.staticTexts["Modules"].click()
        XCTAssertTrue(window.staticTexts["Control app and device audio."].waitForExistence(timeout: 3))
        XCTAssertTrue(window.staticTexts["Stopped"].exists)
        let addAwake = window.buttons["Add Awake"]
        XCTAssertTrue(addAwake.exists)
        addAwake.click()
        XCTAssertTrue(addAwake.waitForNonExistence(timeout: 3))
        let modulesScreenshot = XCTAttachment(screenshot: window.screenshot())
        modulesScreenshot.name = "Semper Shell Modules After Adding Awake"
        modulesScreenshot.lifetime = .keepAlways
        add(modulesScreenshot)

        window.staticTexts["Home"].click()
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "no-matching-shell-action")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(window.staticTexts["Awake"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["No active Awake session"].waitForExistence(timeout: 3))
        window.buttons["Quit Semper"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }
}

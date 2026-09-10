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
        XCTAssertTrue(window.staticTexts["Home"].firstMatch.exists)
        XCTAssertTrue(window.staticTexts["Modules"].firstMatch.exists)
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
            window.staticTexts["No matching actions"]
                .waitForExistence(timeout: 3))

        search.typeKey("a", modifierFlags: .command)
        search.typeText("sound")
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            window.staticTexts["Service startup is unavailable in shell UI tests."].waitForExistence(timeout: 3))
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(window.staticTexts["Your utilities"].exists)
        XCTAssertFalse(window.buttons["Mute current output"].exists)
        search.typeText("no-matching-shell-action")

        window.staticTexts["Modules"].firstMatch.click()
        XCTAssertTrue(window.staticTexts["Control app and device audio."].waitForExistence(timeout: 3))
        XCTAssertTrue(window.staticTexts["Stopped"].firstMatch.exists)
        let moduleSearch = window.textFields["Search modules"]
        moduleSearch.click()
        moduleSearch.typeText("awake")
        XCTAssertFalse(window.staticTexts["Control app and device audio."].exists)
        let addAwake = window.buttons["Add Awake"]
        XCTAssertTrue(addAwake.exists)
        addAwake.click()
        XCTAssertTrue(addAwake.waitForNonExistence(timeout: 3))
        XCTAssertTrue(window.buttons["Open Awake"].exists)
        moduleSearch.typeKey(.escape, modifierFlags: [])
        let modulesScreenshot = XCTAttachment(screenshot: window.screenshot())
        modulesScreenshot.name = "Semper Shell Modules After Adding Awake"
        modulesScreenshot.lifetime = .keepAlways
        add(modulesScreenshot)

        window.staticTexts["Home"].firstMatch.click()
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

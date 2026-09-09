import XCTest

final class AwayModeUITests: XCTestCase {
    private let correctPIN = "0427"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCountdownCanCancelAndStartImmediately() throws {
        let app = launchApp()
        defer { app.terminate() }

        let startButton = app.buttons["Start Away Mode"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.click()

        XCTAssertTrue(app.staticTexts["Starting Away Mode"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["5"].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(startButton.waitForExistence(timeout: 2))

        startButton.click()
        let startNowButton = app.buttons["Start Now"]
        XCTAssertTrue(startNowButton.waitForExistence(timeout: 2))
        startNowButton.click()
        XCTAssertTrue(app.buttons["Authenticate to Exit"].waitForExistence(timeout: 5))

        exitWithPIN(in: app)
    }

    @MainActor
    func testWrongPINRetainsEntryFocusAndCorrectPINExits() throws {
        let app = launchApp()
        defer { app.terminate() }
        startAwayImmediately(in: app)

        app.buttons["Authenticate to Exit"].click()
        let pinField = app.secureTextFields["4-digit PIN"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 3))
        pinField.typeText("1111")
        app.buttons["Exit"].click()

        let authenticationError = app.staticTexts["Authentication error"]
        XCTAssertTrue(authenticationError.waitForExistence(timeout: 2))
        XCTAssertEqual(authenticationError.value as? String, "Wrong PIN.")

        pinField.typeText(correctPIN)
        app.buttons["Exit"].click()
        XCTAssertTrue(
            app.buttons["Start Away Mode"].waitForExistence(timeout: 5),
            "Successful PIN authentication should restore the Away module"
        )
    }

    @MainActor
    func testCurtainExposesPrimaryAccessibilityLabels() throws {
        let app = launchApp()
        defer { app.terminate() }
        startAwayImmediately(in: app)

        XCTAssertTrue(app.staticTexts["Away Mode"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["Local time"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Authenticate to Exit"].exists)

        exitWithPIN(in: app)
    }

    @MainActor
    func testSystemAuthenticationSuccessExitsCurtain() throws {
        let app = launchApp(
            authenticationMethod: "system",
            systemAuthenticationResult: "success"
        )
        defer { app.terminate() }
        startAwayImmediately(in: app)

        app.buttons["Authenticate to Exit"].click()

        XCTAssertTrue(
            app.buttons["Start Away Mode"].waitForExistence(timeout: 5),
            "Successful system authentication should restore the Away module"
        )
    }

    @MainActor
    func testSystemAuthenticationCancellationKeepsCurtainActive() throws {
        let app = launchApp(
            authenticationMethod: "system",
            systemAuthenticationResult: "cancelled"
        )
        defer { app.terminate() }
        startAwayImmediately(in: app)

        app.buttons["Authenticate to Exit"].click()

        let authenticationError = app.staticTexts["Authentication error"]
        XCTAssertTrue(authenticationError.waitForExistence(timeout: 3))
        XCTAssertEqual(
            authenticationError.value as? String,
            "Authentication was cancelled or failed."
        )
        XCTAssertTrue(app.buttons["Authenticate to Exit"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Start Away Mode"].exists)
    }

    @MainActor
    private func launchApp(
        authenticationMethod: String = "pin",
        systemAuthenticationResult: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--away-ui-testing",
            "--away-ui-auth=\(authenticationMethod)",
            "--away-ui-pin=\(correctPIN)",
        ]
        if let systemAuthenticationResult {
            app.launchArguments.append(
                "--away-ui-system-auth=\(systemAuthenticationResult)"
            )
        }
        app.launch()
        XCTAssertTrue(
            app.windows["Semper Away Mode UI Tests"].waitForExistence(timeout: 8),
            "The DEBUG Away UI test host window did not appear"
        )
        return app
    }

    @MainActor
    private func startAwayImmediately(in app: XCUIApplication) {
        let startButton = app.buttons["Start Away Mode"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.click()
        let startNowButton = app.buttons["Start Now"]
        XCTAssertTrue(startNowButton.waitForExistence(timeout: 2))
        startNowButton.click()
        XCTAssertTrue(app.buttons["Authenticate to Exit"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func exitWithPIN(in app: XCUIApplication) {
        app.buttons["Authenticate to Exit"].click()
        let pinField = app.secureTextFields["4-digit PIN"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 3))
        pinField.click()
        pinField.typeText(correctPIN)
        app.buttons["Exit"].click()
        XCTAssertTrue(app.buttons["Start Away Mode"].waitForExistence(timeout: 5))
    }
}

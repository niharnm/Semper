#if DEBUG
    import Testing

    @testable import Semper

    @MainActor
    @Suite("DEBUG shell launch selection")
    struct SemperDebugLaunchModeTests {
        @Test(
            "Explicit shell UI testing precedes either generic XCTest host signal",
            arguments: [false, true], [false, true])
        func shellPrecedesTestHost(hasConfiguration: Bool, hasClass: Bool) {
            #expect(ShellUITestFixture.enabledArgument == "--shell-ui-testing")
            let mode = SemperDebugLaunchMode.select(
                arguments: ["Semper", "--shell-ui-testing"],
                hasXCTestConfiguration: hasConfiguration, hasXCTestClass: hasClass)
            #expect(mode == .shellUITest)
        }

        @Test("Away retains priority when both explicit fixture flags are present", arguments: [false, true])
        func awayPrecedesShell(shellFirst: Bool) throws {
            let flags =
                shellFirst
                ? ["--shell-ui-testing", "--away-ui-testing"]
                : ["--away-ui-testing", "--shell-ui-testing"]
            let arguments = ["Semper"] + flags + ["--away-ui-auth=pin", "--away-ui-pin=0427"]
            let mode = SemperDebugLaunchMode.select(
                arguments: arguments, hasXCTestConfiguration: true, hasXCTestClass: true)
            let options = try #require(AwayUITestLaunchOptions.parse(arguments: arguments))
            #expect(mode == .awayUITest(options))
        }

        @Test(
            "Similar arguments do not enable the shell fixture or change ordinary host selection",
            arguments: [false, true], [false, true])
        func shellRequiresExactFlag(hasConfiguration: Bool, hasClass: Bool) {
            let mode = SemperDebugLaunchMode.select(
                arguments: ["Semper", "--shell-ui-testing=false"],
                hasXCTestConfiguration: hasConfiguration, hasXCTestClass: hasClass)
            #expect(mode == (hasConfiguration || hasClass ? .testHost : .regular))
        }
    }
#endif

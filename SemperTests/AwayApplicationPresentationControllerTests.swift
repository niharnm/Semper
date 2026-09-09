import AppKit
import Testing
@testable import Semper

@Suite("Away application presentation")
@MainActor
struct AwayApplicationPresentationControllerTests {
    @Test("Away keeps recovery controls available and restores exact prior options")
    func recoveryOptionsAndRestoration() throws {
        let prior: NSApplication.PresentationOptions = [
            .autoHideDock,
            .autoHideMenuBar,
            .disableForceQuit,
            .disableSessionTermination,
            .disableAppleMenu,
            .disableHideApplication,
        ]
        let application = AwayPresentationApplicationStub(options: prior)
        let controller = AwayApplicationPresentationController(application: application)

        try controller.begin()

        #expect(controller.isActive)
        #expect(application.presentationOptions.contains(.hideDock))
        #expect(application.presentationOptions.contains(.hideMenuBar))
        #expect(application.presentationOptions.contains(.disableProcessSwitching))
        #expect(application.presentationOptions.contains(.disableHideApplication))
        #expect(!application.presentationOptions.contains(.autoHideDock))
        #expect(!application.presentationOptions.contains(.autoHideMenuBar))
        #expect(!application.presentationOptions.contains(.disableForceQuit))
        #expect(!application.presentationOptions.contains(.disableSessionTermination))
        #expect(!application.presentationOptions.contains(.disableAppleMenu))

        controller.restore()

        #expect(!controller.isActive)
        #expect(application.presentationOptions == prior)
    }

    @Test("A rejected presentation change restores the prior options")
    func rejectedChangeRestoresPriorOptions() {
        let prior: NSApplication.PresentationOptions = [.autoHideDock]
        let application = AwayPresentationApplicationStub(options: prior)
        application.rejectChanges = true
        let controller = AwayApplicationPresentationController(application: application)

        #expect(throws: AwayApplicationPresentationError.couldNotApply) {
            try controller.begin()
        }
        #expect(!controller.isActive)
        #expect(application.presentationOptions == prior)
    }
}

@MainActor
private final class AwayPresentationApplicationStub: AwayPresentationOptionsControlling {
    private var storedOptions: NSApplication.PresentationOptions
    var rejectChanges = false

    init(options: NSApplication.PresentationOptions) {
        storedOptions = options
    }

    var presentationOptions: NSApplication.PresentationOptions {
        get { storedOptions }
        set {
            guard !rejectChanges else { return }
            storedOptions = newValue
        }
    }
}

import AppKit

enum AwayApplicationPresentationError: Error, Equatable {
    case alreadyActive
    case couldNotApply
}

@MainActor
protocol AwayApplicationPresenting: AnyObject {
    var isActive: Bool { get }
    func begin() throws
    func restore()
}

@MainActor
protocol AwayPresentationOptionsControlling: AnyObject {
    var presentationOptions: NSApplication.PresentationOptions { get set }
}

extension NSApplication: AwayPresentationOptionsControlling {}

@MainActor
final class AwayApplicationPresentationController: AwayApplicationPresenting {
    private static let recoveryOptions: NSApplication.PresentationOptions = [
        .disableForceQuit,
        .disableSessionTermination,
        .disableAppleMenu,
    ]

    private let application: any AwayPresentationOptionsControlling
    private var priorOptions: NSApplication.PresentationOptions?

    init(application: any AwayPresentationOptionsControlling = NSApplication.shared) {
        self.application = application
    }

    var isActive: Bool {
        priorOptions != nil
    }

    func begin() throws {
        guard priorOptions == nil else {
            throw AwayApplicationPresentationError.alreadyActive
        }

        let prior = application.presentationOptions
        var requested = prior
        requested.remove([.autoHideDock, .autoHideMenuBar])
        requested.remove(Self.recoveryOptions)
        requested.insert([.hideDock, .hideMenuBar, .disableProcessSwitching])
        application.presentationOptions = requested

        guard application.presentationOptions.contains(.hideDock),
              application.presentationOptions.contains(.hideMenuBar),
              application.presentationOptions.contains(.disableProcessSwitching),
              application.presentationOptions.isDisjoint(with: Self.recoveryOptions) else {
            application.presentationOptions = prior
            throw AwayApplicationPresentationError.couldNotApply
        }
        priorOptions = prior
    }

    func restore() {
        guard let priorOptions else { return }
        application.presentationOptions = priorOptions
        self.priorOptions = nil
    }
}

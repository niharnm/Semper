import AppKit

struct AwayScreenIdentifier: Hashable {
    private enum Value: Hashable {
        case display(CGDirectDisplayID)
        case object(ObjectIdentifier)
    }

    private let value: Value

    init(_ object: AnyObject) {
        value = .object(ObjectIdentifier(object))
    }

    init(displayID: CGDirectDisplayID) {
        value = .display(displayID)
    }
}

struct AwayScreenSnapshot {
    let identifier: AwayScreenIdentifier
    let frame: NSRect
    let backingScaleFactor: CGFloat
    fileprivate let screen: NSScreen?

    init(screen: NSScreen) {
        if let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            identifier = AwayScreenIdentifier(displayID: screenNumber.uint32Value)
        } else {
            identifier = AwayScreenIdentifier(screen)
        }
        frame = screen.frame
        backingScaleFactor = screen.backingScaleFactor
        self.screen = screen
    }

    init(
        identifier: AwayScreenIdentifier,
        frame: NSRect,
        backingScaleFactor: CGFloat = 2
    ) {
        self.identifier = identifier
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
        screen = nil
    }
}

@MainActor
protocol AwayScreenProviding: AnyObject {
    var screens: [AwayScreenSnapshot] { get }
    var primaryScreenIdentifier: AwayScreenIdentifier? { get }
}

@MainActor
final class SystemAwayScreenProvider: AwayScreenProviding {
    var screens: [AwayScreenSnapshot] {
        NSScreen.screens.map(AwayScreenSnapshot.init(screen:))
    }

    var primaryScreenIdentifier: AwayScreenIdentifier? {
        NSScreen.screens.first.map(AwayScreenSnapshot.init(screen:))?.identifier
    }
}

@MainActor
protocol AwayCurtainPanel: AnyObject {
    var frame: NSRect { get }
    var isVisible: Bool { get }
    var isOpaque: Bool { get }
    var level: NSWindow.Level { get }
    var collectionBehavior: NSWindow.CollectionBehavior { get }
    var hidesOnDeactivate: Bool { get }
    var canHide: Bool { get }
    var canBecomeKey: Bool { get }
    var ignoresMouseEvents: Bool { get }
    var sharingType: NSWindow.SharingType { get }

    func orderFront(makeKey: Bool)
    func orderOut()
}

@MainActor
protocol AwayCurtainPanelCreating: AnyObject {
    func makePanel(
        for screen: AwayScreenSnapshot,
        isPrimary: Bool,
        contentView: NSView
    ) throws -> any AwayCurtainPanel
}

enum AwayWindowFailure: Error, Equatable {
    case noScreens
    case primaryScreenUnavailable
    case noPreparedPanels
    case contentCreationFailed
    case panelCreationFailed
    case coverageVerificationFailed
}

enum AwayWindowPreparationResult: Equatable {
    case prepared(screenCount: Int)
    case degraded(AwayWindowFailure)
    case failed(AwayWindowFailure)
}

enum AwayWindowPresentationResult: Equatable {
    case presented(screenCount: Int)
    case degraded(AwayWindowFailure)
    case failed(AwayWindowFailure)
}

@MainActor
final class AwayCurtainPanelFactory: AwayCurtainPanelCreating {
    func makePanel(
        for screen: AwayScreenSnapshot,
        isPrimary: Bool,
        contentView: NSView
    ) throws -> any AwayCurtainPanel {
        guard let nativeScreen = screen.screen else {
            throw AwayWindowFailure.panelCreationFailed
        }

        let panel = AwayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nativeScreen,
            permitsKey: isPrimary
        )
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .readOnly
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        if isPrimary {
            panel.contentView = contentView
        } else {
            let backgroundContainer = AwayBackgroundContainerView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            contentView.frame = backgroundContainer.bounds
            contentView.autoresizingMask = [.width, .height]
            backgroundContainer.addSubview(contentView)
            panel.contentView = backgroundContainer
        }
        panel.setFrame(screen.frame, display: true)
        return panel
    }
}

private final class AwayBackgroundContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }
}

private final class AwayPanel: NSPanel {
    private let permitsKey: Bool

    init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool,
        screen: NSScreen?,
        permitsKey: Bool
    ) {
        self.permitsKey = permitsKey
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag,
            screen: screen
        )
    }

    override var canBecomeKey: Bool { permitsKey }
    override var canBecomeMain: Bool { false }
}

extension AwayPanel: AwayCurtainPanel {
    func orderFront(makeKey: Bool) {
        if makeKey {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }

    func orderOut() {
        orderOut(nil)
    }
}

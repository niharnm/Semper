import AppKit
import Testing
@testable import Semper

@Suite("Away window controller")
@MainActor
struct AwayWindowControllerTests {
    @Test("Direct display identifiers remain stable across snapshot objects")
    func directDisplayIdentifiersRemainStable() {
        let firstObject = NSObject()
        let secondObject = NSObject()

        #expect(
            AwayScreenIdentifier(displayID: 42)
                == AwayScreenIdentifier(displayID: 42)
        )
        #expect(AwayScreenIdentifier(firstObject) == AwayScreenIdentifier(firstObject))
        #expect(AwayScreenIdentifier(firstObject) != AwayScreenIdentifier(secondObject))
    }

    @Test("Prepare builds one hidden panel for each screen")
    func prepareBuildsHiddenPanels() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        var primaryFlags: [Bool] = []

        let result = controller.prepare { _, isPrimary in
            primaryFlags.append(isPrimary)
            return NSView()
        }

        #expect(result == .prepared(screenCount: 2))
        #expect(controller.isPrepared)
        #expect(controller.isPresented == false)
        #expect(factory.panels.count == 2)
        #expect(factory.panels.allSatisfy { !$0.isVisible })
        #expect(primaryFlags == [true, false])
    }

    @Test("Prepared panels cover full screen frames when presented")
    func preparedPanelsCoverScreenFrames() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)

        #expect(controller.prepare { _, _ in NSView() } == .prepared(screenCount: 2))
        #expect(controller.presentPrepared() == .presented(screenCount: 2))

        #expect(controller.panelCount == 2)
        #expect(Set(controller.coveredFrames) == Set(Self.twoFrames))
        #expect(factory.panels[0].canBecomeKey)
        #expect(factory.panels[1].canBecomeKey == false)
        #expect(factory.panels.allSatisfy { $0.isOpaque })
        #expect(factory.panels.allSatisfy { $0.level == .screenSaver })
        #expect(factory.panels.allSatisfy { !$0.ignoresMouseEvents })
        #expect(factory.panels.allSatisfy { $0.sharingType == .readOnly })
    }

    @Test("Secondary panels order before the primary panel")
    func secondaryPanelsOrderFirst() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.prepare { _, _ in NSView() }

        _ = controller.presentPrepared()

        #expect(factory.events.values == ["panel2.front", "panel1.key"])
    }

    @Test("Replacement panels order before prior panels are removed")
    func replacementOrdersBeforePriorRemoval() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.present { _, _ in NSView() }
        factory.events.values = []
        provider.replaceScreens(frames: [
            NSRect(x: 0, y: 0, width: 1728, height: 1117),
            NSRect(x: 1728, y: 0, width: 1280, height: 720),
            NSRect(x: -1024, y: 0, width: 1024, height: 768),
        ])

        let result = controller.reconcileScreens()

        #expect(result == .presented(screenCount: 3))
        let lastFront = factory.events.values.lastIndex { $0.contains("front") || $0.contains("key") }
        let firstPriorOut = factory.events.values.firstIndex(of: "panel1.out")
        #expect(lastFront != nil)
        #expect(firstPriorOut != nil)
        if let lastFront, let firstPriorOut {
            #expect(lastFront < firstPriorOut)
        }
    }

    @Test("Failed replacement keeps prior panels visible and reports degraded")
    func failedReplacementKeepsPriorPanels() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))
        factory.panelsThatStayHidden.insert(4)
        provider.replaceScreens(frames: [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: 1920, y: 0, width: 1440, height: 900),
        ])
        var reportedFailure: AwayWindowFailure?
        controller.onDegraded = { reportedFailure = $0 }

        let result = controller.reconcileScreens()

        #expect(result == .degraded(.coverageVerificationFailed))
        #expect(controller.panelCount == 2)
        #expect(priorPanels.allSatisfy { $0.isVisible })
        #expect(factory.panels[2].isVisible == false)
        #expect(factory.panels[3].isVisible == false)
        #expect(reportedFailure == .coverageVerificationFailed)
    }

    @Test("A transient replacement failure retries once")
    func transientReplacementFailureRetries() async {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            observesLifecycle: false,
            retrySleep: { _ in }
        )
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))
        factory.panelsThatStayHidden.insert(4)
        provider.replaceScreens(frames: Self.twoFrames)

        #expect(controller.reconcileScreens() == .degraded(.coverageVerificationFailed))
        factory.panelsThatStayHidden.remove(4)
        for _ in 0..<8 {
            await Task.yield()
        }

        #expect(factory.panels.count == 6)
        #expect(priorPanels.allSatisfy { !$0.isVisible })
        #expect(factory.panels.suffix(2).allSatisfy { $0.isVisible })
        #expect(controller.panelCount == 2)
    }

    @Test("Persistent replacement failure uses bounded retries and keeps prior panels")
    func persistentReplacementFailureUsesBoundedRetries() async {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            observesLifecycle: false,
            retrySleep: { _ in },
            reconciliationRetryDelays: [.zero, .zero, .zero]
        )
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))
        factory.panelsThatStayHidden.formUnion([4, 6, 8, 10])

        #expect(controller.reconcileScreens() == .degraded(.coverageVerificationFailed))
        for _ in 0..<128 where factory.panels.count < 10 {
            await Task.yield()
        }

        #expect(factory.panels.count == 10)
        #expect(controller.panelCount == 2)
        #expect(priorPanels.allSatisfy { $0.isVisible })
        #expect(controller.lastFailure == .coverageVerificationFailed)
    }

    @Test("Panel creation failure preserves the active curtain set")
    func panelCreationFailurePreservesActiveSet() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))
        factory.failedCreationNumbers.insert(4)
        provider.replaceScreens(frames: Self.twoFrames)

        let result = controller.reconcileScreens()

        #expect(result == .degraded(.panelCreationFailed))
        #expect(controller.panelCount == 2)
        #expect(priorPanels.allSatisfy { $0.isVisible })
        #expect(priorPanels.allSatisfy { !$0.events.values.contains("\($0.label).out") })
    }

    @Test("Active session reconciles screens and Space changes reorder replacements")
    func lifecycleNotificationsReconcileAndReorderPanels() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            applicationNotificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter
        )
        _ = controller.present { _, _ in NSView() }
        factory.events.values = []
        provider.replaceScreens(frames: [
            Self.twoFrames[0],
            Self.twoFrames[1],
            NSRect(x: 1512, y: 0, width: 1280, height: 720),
        ])

        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        #expect(factory.events.values == [
            "panel4.front",
            "panel5.front",
            "panel3.key",
            "panel1.out",
            "panel2.out",
            "panel4.front",
            "panel5.front",
            "panel3.key",
        ])
        #expect(controller.panelCount == 3)
    }

    @Test("Wake retries full display reconciliation")
    func wakeReconcilesScreens() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            applicationNotificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter
        )
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(factory.panels.count == 4)
        #expect(priorPanels.allSatisfy { !$0.isVisible })
        #expect(factory.panels.suffix(2).allSatisfy { $0.isVisible })
    }

    @Test("Topology changes during presentation keep the prior curtains")
    func topologyRaceKeepsPriorCurtains() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.present { _, _ in NSView() }
        let priorPanels = Array(factory.panels.prefix(2))
        _ = controller.prepare { _, _ in NSView() }
        provider.replaceScreens(frames: [Self.twoFrames[0]])

        let result = controller.presentPrepared()

        #expect(result == .degraded(.coverageVerificationFailed))
        #expect(priorPanels.allSatisfy { $0.isVisible })
        #expect(factory.panels.suffix(2).allSatisfy { !$0.isVisible })
    }

    @Test("Screen parameter notification replaces the curtain set")
    func screenNotificationReplacesPanels() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            applicationNotificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter
        )
        _ = controller.present { _, _ in NSView() }
        provider.replaceScreens(frames: [Self.twoFrames[0]])

        appCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(controller.panelCount == 1)
        #expect(controller.coveredFrames == [Self.twoFrames[0]])
    }

    @Test("Dismiss removes active and prepared panels")
    func dismissRemovesAllPanels() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)
        _ = controller.present { _, _ in NSView() }
        _ = controller.prepare { _, _ in NSView() }

        controller.dismiss()

        #expect(controller.isPresented == false)
        #expect(controller.isPrepared == false)
        #expect(factory.panels.allSatisfy { !$0.isVisible })
    }

    @Test("Presentation without prepared panels fails")
    func presentationRequiresPreparation() {
        let provider = RecordingAwayScreenProvider(frames: Self.twoFrames)
        let factory = RecordingAwayPanelFactory()
        let controller = makeController(provider: provider, factory: factory)

        #expect(controller.presentPrepared() == .failed(.noPreparedPanels))
    }

    private func makeController(
        provider: RecordingAwayScreenProvider,
        factory: RecordingAwayPanelFactory
    ) -> AwayWindowController {
        AwayWindowController(
            screenProvider: provider,
            panelFactory: factory,
            observesLifecycle: false
        )
    }

    private static let twoFrames = [
        NSRect(x: 0, y: 0, width: 1512, height: 982),
        NSRect(x: -1920, y: 82, width: 1920, height: 1080),
    ]
}

@MainActor
private final class RecordingAwayScreenProvider: AwayScreenProviding {
    private var retainedTokens: [NSObject] = []
    var screens: [AwayScreenSnapshot] = []
    var primaryScreenIdentifier: AwayScreenIdentifier?

    init(frames: [NSRect]) {
        replaceScreens(frames: frames)
    }

    func replaceScreens(frames: [NSRect]) {
        let tokens = frames.map { _ in NSObject() }
        retainedTokens.append(contentsOf: tokens)
        screens = zip(tokens, frames).map { token, frame in
            AwayScreenSnapshot(identifier: AwayScreenIdentifier(token), frame: frame)
        }
        primaryScreenIdentifier = screens.first?.identifier
    }
}

@MainActor
private final class RecordingAwayPanelFactory: AwayCurtainPanelCreating {
    let events = AwayPanelEventLog()
    private(set) var panels: [RecordingAwayPanel] = []
    var failedCreationNumbers: Set<Int> = []
    var panelsThatStayHidden: Set<Int> = []
    private var creationCount = 0

    func makePanel(
        for screen: AwayScreenSnapshot,
        isPrimary: Bool,
        contentView: NSView
    ) throws -> any AwayCurtainPanel {
        creationCount += 1
        if failedCreationNumbers.contains(creationCount) {
            throw AwayWindowFailure.panelCreationFailed
        }
        let panel = RecordingAwayPanel(
            label: "panel\(creationCount)",
            frame: screen.frame,
            isPrimary: isPrimary,
            events: events,
            showsWhenOrdered: !panelsThatStayHidden.contains(creationCount)
        )
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class RecordingAwayPanel: AwayCurtainPanel {
    let label: String
    let frame: NSRect
    let isOpaque = true
    let level: NSWindow.Level = .screenSaver
    let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]
    let hidesOnDeactivate = false
    let canHide = false
    let canBecomeKey: Bool
    let ignoresMouseEvents = false
    let sharingType: NSWindow.SharingType = .readOnly
    let events: AwayPanelEventLog
    let showsWhenOrdered: Bool
    var isVisible = false

    init(
        label: String,
        frame: NSRect,
        isPrimary: Bool,
        events: AwayPanelEventLog,
        showsWhenOrdered: Bool
    ) {
        self.label = label
        self.frame = frame
        canBecomeKey = isPrimary
        self.events = events
        self.showsWhenOrdered = showsWhenOrdered
    }

    func orderFront(makeKey: Bool) {
        events.values.append("\(label).\(makeKey ? "key" : "front")")
        isVisible = showsWhenOrdered
    }

    func orderOut() {
        events.values.append("\(label).out")
        isVisible = false
    }
}

@MainActor
private final class AwayPanelEventLog {
    var values: [String] = []
}

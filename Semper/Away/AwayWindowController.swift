import AppKit

@MainActor
final class AwayWindowController {
    typealias ContentBuilder = @MainActor (AwayScreenSnapshot, Bool) throws -> NSView
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct PanelRecord {
        let screen: AwayScreenSnapshot
        let isPrimary: Bool
        let panel: any AwayCurtainPanel
    }

    private struct ObserverRecord {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private static let requiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    private let screenProvider: any AwayScreenProviding
    private let panelFactory: any AwayCurtainPanelCreating
    private let retrySleep: Sleep
    private let reconciliationRetryDelays: [Duration]
    private var panels: [PanelRecord] = []
    private var preparedPanels: [PanelRecord] = []
    private var contentBuilder: ContentBuilder?
    private var observers: [ObserverRecord] = []
    private var reconciliationRetryTask: Task<Void, Never>?
    private var reconciliationRetryAttempt = 0

    private(set) var lastFailure: AwayWindowFailure?
    private(set) var lastPreparationResult: AwayWindowPreparationResult?
    private(set) var lastPresentationResult: AwayWindowPresentationResult?
    var onDegraded: ((AwayWindowFailure) -> Void)?
    var onRestored: (() -> Void)?

    var isPresented: Bool { !panels.isEmpty }
    var isPrepared: Bool { !preparedPanels.isEmpty }
    var panelCount: Int { panels.count }
    var coveredFrames: [NSRect] { panels.map(\.screen.frame) }
    var primaryScreenIdentifier: AwayScreenIdentifier? {
        panels.first(where: \.isPrimary)?.screen.identifier
    }

    init(
        screenProvider: any AwayScreenProviding = SystemAwayScreenProvider(),
        panelFactory: any AwayCurtainPanelCreating = AwayCurtainPanelFactory(),
        applicationNotificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observesLifecycle: Bool = true,
        retrySleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        reconciliationRetryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
        ]
    ) {
        self.screenProvider = screenProvider
        self.panelFactory = panelFactory
        self.retrySleep = retrySleep
        self.reconciliationRetryDelays = reconciliationRetryDelays

        if observesLifecycle {
            observe(
                NSApplication.didChangeScreenParametersNotification,
                center: applicationNotificationCenter
            ) { [weak self] in
                _ = self?.reconcileScreens()
            }
            observe(NSWorkspace.didWakeNotification, center: workspaceNotificationCenter) { [weak self] in
                _ = self?.reconcileScreens()
            }
            observe(
                NSWorkspace.screensDidWakeNotification,
                center: workspaceNotificationCenter
            ) { [weak self] in
                _ = self?.reconcileScreens()
            }
            observe(
                NSWorkspace.sessionDidBecomeActiveNotification,
                center: workspaceNotificationCenter
            ) { [weak self] in
                _ = self?.reconcileScreens()
            }
            observe(
                NSWorkspace.activeSpaceDidChangeNotification,
                center: workspaceNotificationCenter
            ) { [weak self] in
                self?.reorderPanels()
            }
        }
    }

    isolated deinit {
        reconciliationRetryTask?.cancel()
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
    }

    @discardableResult
    func present(contentBuilder: @escaping ContentBuilder) -> AwayWindowPresentationResult {
        let result: AwayWindowPresentationResult
        switch prepare(contentBuilder: contentBuilder) {
        case .prepared:
            result = presentPrepared()
        case .degraded(let failure):
            result = .degraded(failure)
        case .failed(let failure):
            result = .failed(failure)
        }
        lastPresentationResult = result
        return result
    }

    @discardableResult
    func prepare(contentBuilder: @escaping ContentBuilder) -> AwayWindowPreparationResult {
        self.contentBuilder = contentBuilder
        let screens = screenProvider.screens
        guard !screens.isEmpty else {
            return reportPreparation(.noScreens)
        }
        guard let primaryIdentifier = screenProvider.primaryScreenIdentifier,
              screens.contains(where: { $0.identifier == primaryIdentifier }) else {
            return reportPreparation(.primaryScreenUnavailable)
        }
        guard Set(screens.map(\.identifier)).count == screens.count else {
            return reportPreparation(.coverageVerificationFailed)
        }

        var replacements: [PanelRecord] = []
        do {
            for screen in screens {
                let isPrimary = screen.identifier == primaryIdentifier
                let contentView: NSView
                do {
                    contentView = try contentBuilder(screen, isPrimary)
                } catch {
                    throw AwayWindowFailure.contentCreationFailed
                }
                contentView.frame = NSRect(origin: .zero, size: screen.frame.size)
                contentView.autoresizingMask = [.width, .height]

                let panel: any AwayCurtainPanel
                do {
                    panel = try panelFactory.makePanel(
                        for: screen,
                        isPrimary: isPrimary,
                        contentView: contentView
                    )
                } catch {
                    throw AwayWindowFailure.panelCreationFailed
                }
                replacements.append(
                    PanelRecord(screen: screen, isPrimary: isPrimary, panel: panel)
                )
            }
        } catch let failure as AwayWindowFailure {
            hide(records: replacements)
            return reportPreparation(failure)
        } catch {
            hide(records: replacements)
            return reportPreparation(.panelCreationFailed)
        }

        guard verifiesConfiguration(records: replacements, screens: screens, visible: false) else {
            hide(records: replacements)
            return reportPreparation(.coverageVerificationFailed)
        }

        hide(records: preparedPanels)
        preparedPanels = replacements
        lastFailure = nil
        let result = AwayWindowPreparationResult.prepared(screenCount: replacements.count)
        lastPreparationResult = result
        return result
    }

    @discardableResult
    func presentPrepared() -> AwayWindowPresentationResult {
        guard !preparedPanels.isEmpty else {
            return reportPresentation(.noPreparedPanels)
        }

        let replacements = preparedPanels
        let currentScreens = screenProvider.screens
        guard currentScreens.count == replacements.count,
              Set(currentScreens.map(\.identifier)).count == currentScreens.count,
              let currentPrimaryIdentifier = screenProvider.primaryScreenIdentifier,
              Set(currentScreens.map(\.identifier)) == Set(replacements.map(\.screen.identifier)),
              replacements.contains(where: {
                  $0.isPrimary && $0.screen.identifier == currentPrimaryIdentifier
              }) else {
            hide(records: replacements)
            preparedPanels = []
            reorderPanels()
            return reportPresentation(.coverageVerificationFailed)
        }
        order(records: replacements)
        guard verifiesConfiguration(
            records: replacements,
            screens: currentScreens,
            visible: true
        ) else {
            hide(records: replacements)
            preparedPanels = []
            reorderPanels()
            return reportPresentation(.coverageVerificationFailed)
        }

        let priorPanels = panels
        panels = replacements
        preparedPanels = []
        for record in priorPanels {
            record.panel.orderOut()
        }

        lastFailure = nil
        reconciliationRetryTask?.cancel()
        reconciliationRetryTask = nil
        reconciliationRetryAttempt = 0
        let result = AwayWindowPresentationResult.presented(screenCount: replacements.count)
        lastPresentationResult = result
        onRestored?()
        return result
    }

    @discardableResult
    func reconcileScreens() -> AwayWindowPresentationResult? {
        reconciliationRetryTask?.cancel()
        reconciliationRetryTask = nil
        reconciliationRetryAttempt = 0
        return performReconciliation()
    }

    private func performReconciliation() -> AwayWindowPresentationResult? {
        guard !panels.isEmpty, let contentBuilder else { return nil }
        let result: AwayWindowPresentationResult
        switch prepare(contentBuilder: contentBuilder) {
        case .prepared:
            result = presentPrepared()
        case .degraded(let failure):
            result = .degraded(failure)
        case .failed(let failure):
            result = .failed(failure)
        }
        lastPresentationResult = result
        if case .presented = result {
            reconciliationRetryAttempt = 0
        } else {
            scheduleReconciliationRetry()
        }
        return result
    }

    func reorderPanels() {
        guard !panels.isEmpty else { return }
        order(records: panels)
    }

    func dismiss() {
        reconciliationRetryTask?.cancel()
        reconciliationRetryTask = nil
        reconciliationRetryAttempt = 0
        let priorPanels = panels
        let pendingPanels = preparedPanels
        panels = []
        preparedPanels = []
        contentBuilder = nil
        lastFailure = nil
        lastPreparationResult = nil
        lastPresentationResult = nil
        for record in priorPanels {
            record.panel.orderOut()
        }
        for record in pendingPanels {
            record.panel.orderOut()
        }
    }

    private func verifiesConfiguration(
        records: [PanelRecord],
        screens: [AwayScreenSnapshot],
        visible: Bool
    ) -> Bool {
        guard records.count == screens.count,
              Set(screens.map(\.identifier)).count == screens.count,
              Set(records.map(\.screen.identifier)).count == records.count,
              records.filter(\.isPrimary).count == 1 else {
            return false
        }

        let requestedFrames = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.identifier, $0.frame) }
        )
        for record in records {
            let panel = record.panel
            guard requestedFrames[record.screen.identifier] == panel.frame,
                  panel.isVisible == visible,
                  panel.isOpaque,
                  panel.level == .screenSaver,
                  panel.collectionBehavior == Self.requiredCollectionBehavior,
                  !panel.hidesOnDeactivate,
                  !panel.canHide,
                  panel.canBecomeKey == record.isPrimary,
                  !panel.ignoresMouseEvents,
                  panel.sharingType == .readOnly else {
                return false
            }
        }
        return true
    }

    private func order(records: [PanelRecord]) {
        for record in records where !record.isPrimary {
            record.panel.orderFront(makeKey: false)
        }
        for record in records where record.isPrimary {
            record.panel.orderFront(makeKey: true)
        }
    }

    private func hide(records: [PanelRecord]) {
        for record in records {
            record.panel.orderOut()
        }
    }

    private func scheduleReconciliationRetry() {
        guard reconciliationRetryTask == nil,
              !panels.isEmpty,
              reconciliationRetryAttempt < reconciliationRetryDelays.count else { return }
        let delay = reconciliationRetryDelays[reconciliationRetryAttempt]
        reconciliationRetryAttempt += 1
        let retrySleep = retrySleep
        reconciliationRetryTask = Task { @MainActor [weak self, retrySleep] in
            do {
                try await retrySleep(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            reconciliationRetryTask = nil
            _ = performReconciliation()
        }
    }

    private func reportPreparation(_ failure: AwayWindowFailure) -> AwayWindowPreparationResult {
        hide(records: preparedPanels)
        preparedPanels = []
        lastFailure = failure
        let result: AwayWindowPreparationResult
        if panels.isEmpty {
            result = .failed(failure)
        } else {
            result = .degraded(failure)
            onDegraded?(failure)
        }
        lastPreparationResult = result
        return result
    }

    private func reportPresentation(_ failure: AwayWindowFailure) -> AwayWindowPresentationResult {
        lastFailure = failure
        let result: AwayWindowPresentationResult
        if panels.isEmpty {
            result = .failed(failure)
        } else {
            result = .degraded(failure)
            onDegraded?(failure)
        }
        lastPresentationResult = result
        return result
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter,
        handler: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observers.append(ObserverRecord(center: center, token: token))
    }
}

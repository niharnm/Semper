import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Semper

@MainActor
private final class AwayCoordinatorEventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

@MainActor
private final class AwayCoordinatorPowerBackend: PowerAssertionCreating {
    let log: AwayCoordinatorEventLog
    var failingKinds: Set<PowerAssertionKind> = []
    var failingReleaseIDs: Set<PowerAssertionID> = []
    private(set) var activeIDs: Set<PowerAssertionID> = []
    private var nextID: PowerAssertionID = 1

    init(log: AwayCoordinatorEventLog) {
        self.log = log
    }

    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID {
        switch kind {
        case .preventIdleSystemSleep:
            log.append("power.create.system")
        case .preventIdleDisplaySleep:
            log.append("power.create.display")
        }
        guard !failingKinds.contains(kind) else {
            throw PowerAssertionError.creationFailed(kIOReturnError)
        }
        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        return id
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        log.append("power.release.\(id)")
        guard !failingReleaseIDs.contains(id) else {
            throw .releaseFailed(kIOReturnError)
        }
        activeIDs.remove(id)
    }
}

@MainActor
private final class AwayCoordinatorExpiryScheduler: AwakeExpiryScheduling {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {}
    func cancelScheduledExpiry() {}
}

@MainActor
private final class AwayCoordinatorWindows: AwayWindowManaging {
    let log: AwayCoordinatorEventLog
    var isPresented = false
    var onDegraded: ((AwayWindowFailure) -> Void)?
    var onRestored: (() -> Void)?
    var preparationResult: AwayWindowPreparationResult = .prepared(screenCount: 2)
    var presentationResult: AwayWindowPresentationResult = .presented(screenCount: 2)
    var onPresent: (() -> Void)?
    private(set) var prepareCallCount = 0

    init(log: AwayCoordinatorEventLog) {
        self.log = log
    }

    func prepare(
        contentBuilder: @escaping @MainActor (AwayScreenSnapshot, Bool) throws -> NSView
    ) -> AwayWindowPreparationResult {
        prepareCallCount += 1
        log.append("windows.prepare")
        return preparationResult
    }

    func presentPrepared() -> AwayWindowPresentationResult {
        log.append("windows.present")
        if case .presented = presentationResult {
            isPresented = true
        }
        onPresent?()
        return presentationResult
    }

    func reorderPanels() {
        log.append("windows.reorder")
    }

    func dismiss() {
        log.append("windows.dismiss")
        isPresented = false
    }

    func sendCoverageFailure() {
        onDegraded?(.coverageVerificationFailed)
    }

    func sendCoverageRestored() {
        onRestored?()
    }
}

@MainActor
private final class AwayCoordinatorInputGuard: AwayInputGuarding {
    let log: AwayCoordinatorEventLog
    var isActive = false
    var isFilteringOperational = false
    var hasEventAccess = true
    var onActivity: (() -> Void)?
    var onAuthenticationRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?
    var onFailure: ((AwayInputGuardFailure) -> Void)?
    var onRestored: (() -> Void)?
    var preflightResult = true
    var startResult = true
    private(set) var preflightCallCount = 0
    private(set) var policies: [AwayInputPolicy] = []
    private(set) var authenticationShortcut: ShortcutCodable?

    init(log: AwayCoordinatorEventLog) {
        self.log = log
    }

    func preflight() -> Bool {
        preflightCallCount += 1
        log.append("input.preflight")
        return preflightResult
    }

    func requestEventAccess() {
        log.append("input.requestAccess")
    }

    func start(policy: AwayInputPolicy) -> Bool {
        log.append("input.start.\(policy.logName)")
        policies.append(policy)
        isActive = startResult
        isFilteringOperational = startResult
        return startResult
    }

    func setPolicy(_ policy: AwayInputPolicy) {
        log.append("input.policy.\(policy.logName)")
        policies.append(policy)
    }

    func setAuthenticationShortcut(_ shortcut: ShortcutCodable?) {
        authenticationShortcut = shortcut
    }

    func handleTapDisabled() {
        log.append("input.recover")
    }

    func stop() {
        log.append("input.stop")
        isActive = false
        isFilteringOperational = false
    }

    func sendActivity() {
        onActivity?()
    }

    func sendAuthenticationRequest() {
        onAuthenticationRequested?()
    }

    func sendQuitRequest() {
        onQuitRequested?()
    }

    func sendFailure() {
        isFilteringOperational = false
        onFailure?(.tapRecoveryFailed)
    }

    func sendRestored() {
        isActive = true
        isFilteringOperational = true
        onRestored?()
    }
}

private extension AwayInputPolicy {
    var logName: String {
        switch self {
        case .fullFiltering: "full"
        case .pinEntry: "pin"
        case .systemAuthentication: "system"
        }
    }
}

private enum AwayCoordinatorTestError: Error {
    case expected
}

@MainActor
private final class AwayCoordinatorAuthenticator: AwaySystemAuthenticating {
    struct Plan {
        let succeeds: Bool
        let yieldCount: Int
    }

    let log: AwayCoordinatorEventLog
    var available = true
    var plans: [Plan] = [Plan(succeeds: true, yieldCount: 0)]
    private(set) var reasons: [String] = []

    init(log: AwayCoordinatorEventLog) {
        self.log = log
    }

    func isAvailable() -> Bool {
        log.append("auth.available")
        return available
    }

    func authenticate(reason: String) async throws {
        reasons.append(reason)
        log.append("auth.authenticate")
        let plan = plans.isEmpty ? Plan(succeeds: true, yieldCount: 0) : plans.removeFirst()
        for _ in 0..<plan.yieldCount {
            await Task.yield()
        }
        if !plan.succeeds {
            throw AwayCoordinatorTestError.expected
        }
    }
}

private final class AwayCoordinatorPINStore: AwayPINStoring, @unchecked Sendable {
    private let preparationLock = NSLock()
    private var preparationHasStarted = false
    private let removalLock = NSLock()
    private var removalHasStarted = false
    var hasStoredPIN = true
    var hasPINError: Error?
    var verifyError: Error?
    var prepareError: Error?
    var commitError: Error?
    var removeError: Error?
    var allowPreparationToFinish: DispatchSemaphore?
    var allowRemovalToFinish: DispatchSemaphore?
    var allowVerificationToFinish: DispatchSemaphore?
    var acceptedPIN = "0123"
    private(set) var verifiedCandidates: [String] = []
    private(set) var preparedPINs: [String] = []
    private(set) var storedPINs: [String] = []
    private(set) var removeCallCount = 0

    var didStartPreparation: Bool {
        preparationLock.withLock { preparationHasStarted }
    }

    var didStartRemoval: Bool {
        removalLock.withLock { removalHasStarted }
    }

    func hasPIN() throws -> Bool {
        if let hasPINError { throw hasPINError }
        return hasStoredPIN
    }

    func preparePIN(_ pin: String) throws -> AwayPreparedPIN {
        preparationLock.withLock {
            preparationHasStarted = true
        }
        allowPreparationToFinish?.wait()
        if let prepareError { throw prepareError }
        preparedPINs.append(pin)
        return AwayPreparedPIN(data: Data(pin.utf8))
    }

    func commitPIN(_ preparedPIN: AwayPreparedPIN) throws {
        if let commitError { throw commitError }
        let pin = String(decoding: preparedPIN.data, as: UTF8.self)
        storedPINs.append(pin)
        acceptedPIN = pin
        hasStoredPIN = true
    }

    func verifyPIN(_ pin: String) throws -> Bool {
        verifiedCandidates.append(pin)
        allowVerificationToFinish?.wait()
        if let verifyError { throw verifyError }
        return pin == acceptedPIN
    }

    func removePIN() throws {
        removeCallCount += 1
        removalLock.withLock {
            removalHasStarted = true
        }
        allowRemovalToFinish?.wait()
        if let removeError { throw removeError }
        hasStoredPIN = false
    }
}

private final class AwayCoordinatorPhotoStore: AwayPhotoStoring, @unchecked Sendable {
    var importedPhoto = AwayManagedPhoto(
        filename: "away-photo-11111111-1111-1111-1111-111111111111.jpg",
        pixelWidth: 1600,
        pixelHeight: 900
    )
    var importError: Error?
    var removeError: Error?
    var cleanupError: Error?
    private(set) var importedSourceURLs: [URL] = []
    private(set) var removalAttempts: [String] = []
    private(set) var removedFilenames: [String] = []
    private(set) var cleanupCallCount = 0
    private(set) var cleanupKeptFilenames: [String?] = []

    func importPhoto(from sourceURL: URL) throws -> AwayManagedPhoto {
        importedSourceURLs.append(sourceURL)
        if let importError { throw importError }
        return importedPhoto
    }

    func managedPhotoURL(for filename: String) throws -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(filename)
    }

    func removePhoto(named filename: String) throws {
        removalAttempts.append(filename)
        if let removeError { throw removeError }
        removedFilenames.append(filename)
    }

    func removeUnreferencedPhotos(keeping filename: String?) throws {
        cleanupCallCount += 1
        cleanupKeptFilenames.append(filename)
        if let cleanupError { throw cleanupError }
    }
}

private actor AwayCoordinatorSleepProbe {
    private var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await Task.sleep(for: .seconds(3_600))
    }

    func callCount(for duration: Duration) -> Int {
        durations.filter { $0 == duration }.count
    }
}

private actor AwayCoordinatorDisarmGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        guard duration == .milliseconds(160), !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class AwayCoordinatorPresentation: AwayApplicationPresenting {
    let log: AwayCoordinatorEventLog
    var isActive = false
    var beginFails = false

    init(log: AwayCoordinatorEventLog) {
        self.log = log
    }

    func begin() throws {
        log.append("presentation.begin")
        if beginFails {
            throw AwayCoordinatorTestError.expected
        }
        isActive = true
    }

    func restore() {
        log.append("presentation.restore")
        isActive = false
    }
}

@MainActor
private final class AwayCoordinatorPowerSource: AwayPowerReadingSource {
    var reading: AwayPowerReading
    private var handler: (@MainActor @Sendable () -> Void)?
    private(set) var stopCallCount = 0

    init(reading: AwayPowerReading = AwayPowerReading(
        isLowPowerModeEnabled: false,
        thermalPressure: .nominal,
        powerSupply: .ac(percentage: 80, isCharging: false)
    )) {
        self.reading = reading
    }

    func currentReading() -> AwayPowerReading {
        reading
    }

    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func stopMonitoring() {
        stopCallCount += 1
        handler = nil
    }

    func sendChange() {
        handler?()
    }
}

@MainActor
private final class AwayCoordinatorClock {
    var current = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
private final class AwayCoordinatorHarness {
    let log: AwayCoordinatorEventLog
    let backend: AwayCoordinatorPowerBackend
    let awakeService: AwakeService
    let windows: AwayCoordinatorWindows
    let input: AwayCoordinatorInputGuard
    let authenticator: AwayCoordinatorAuthenticator
    let pinStore: AwayCoordinatorPINStore
    let photoStore: AwayCoordinatorPhotoStore
    let presentation: AwayCoordinatorPresentation
    let powerSource: AwayCoordinatorPowerSource
    let clock: AwayCoordinatorClock
    let settings: SettingsManager
    let mutationAdmission: MutationAdmissionGate
    let coordinator: AwayModeCoordinator

    init(
        authenticationMethod: AwayAuthenticationMethod = .system,
        disclosureCompleted: Bool = true,
        keepsDisplayAwake: Bool = false,
        sleep: @escaping AwayModeCoordinator.Sleep = { _ in },
        persistenceWriter: SettingsPersistenceWriter = SettingsPersistenceWriter(
            writeData: { _, _ in }
        )
    ) {
        let log = AwayCoordinatorEventLog()
        let pinStore = AwayCoordinatorPINStore()
        let powerSource = AwayCoordinatorPowerSource()
        let clock = AwayCoordinatorClock()
        let backend = AwayCoordinatorPowerBackend(log: log)
        let awakeService = AwakeService(
            backend: backend,
            scheduler: AwayCoordinatorExpiryScheduler(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            workspaceNotificationCenter: NotificationCenter()
        )
        let windows = AwayCoordinatorWindows(log: log)
        let input = AwayCoordinatorInputGuard(log: log)
        let authenticator = AwayCoordinatorAuthenticator(log: log)
        let photoStore = AwayCoordinatorPhotoStore()
        let presentation = AwayCoordinatorPresentation(log: log)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperAwayCoordinatorTests-\(UUID().uuidString)")
        let settings = SettingsManager(
            directory: directory,
            persistenceWriter: persistenceWriter
        )
        var appSettings = settings.appSettings
        appSettings.awayModePreferences = AwayModePreferences(
            authenticationMethod: authenticationMethod,
            disclosureCompleted: disclosureCompleted,
            keepsDisplayAwake: keepsDisplayAwake
        )
        settings.appSettings = appSettings
        let powerPolicy = AwayPowerPolicy(source: powerSource)
        let mutationAdmission = MutationAdmissionGate()
        let coordinator = AwayModeCoordinator(
            settings: settings,
            awakeService: awakeService,
            mutationAdmission: mutationAdmission,
            windows: windows,
            inputGuard: input,
            authenticator: authenticator,
            pinStore: pinStore,
            photoStore: photoStore,
            presentation: presentation,
            powerPolicy: powerPolicy,
            now: { [clock] in clock.current },
            sleep: sleep
        )
        self.log = log
        self.pinStore = pinStore
        self.photoStore = photoStore
        self.powerSource = powerSource
        self.clock = clock
        self.mutationAdmission = mutationAdmission
        self.backend = backend
        self.awakeService = awakeService
        self.windows = windows
        self.input = input
        self.authenticator = authenticator
        self.presentation = presentation
        self.settings = settings
        self.coordinator = coordinator
        coordinator.makeCurtainContent = { _, _ in NSView(frame: .zero) }
    }

    func enterGuarded() {
        coordinator.startCountdown()
        coordinator.startNow()
    }
}

@MainActor
@Suite("Away Mode coordinator", .serialized)
struct AwayModeCoordinatorTests {
    @Test("Countdown starts at five and can be cancelled")
    func countdownCancellation() {
        let subject = AwayCoordinatorHarness()

        subject.coordinator.startCountdown()
        #expect(subject.coordinator.state == .countdown(remainingSeconds: 5))
        subject.coordinator.cancelCountdown()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.backend.activeIDs.isEmpty)
        #expect(subject.windows.prepareCallCount == 0)
    }

    @Test("Countdown installs the configured Away shortcut in the active input filter")
    func countdownInstallsAwayShortcut() {
        let subject = AwayCoordinatorHarness()
        let shortcut = ShortcutCodable(
            keyCode: kVK_ANSI_L,
            modifiers: UInt(cmdKey | optionKey)
        )
        var appSettings = subject.settings.appSettings
        appSettings.customShortcuts[ShortcutAction.toggleAwayMode.rawValue] = shortcut
        subject.settings.appSettings = appSettings

        subject.coordinator.startCountdown()

        #expect(subject.input.authenticationShortcut == shortcut)
        subject.coordinator.cancelCountdown()
    }

    @Test("Start Now arms once in dependency order")
    func startNowAndDuplicateEntry() {
        let subject = AwayCoordinatorHarness()
        var stateAtWillGuard: AwayModeState?
        subject.coordinator.onWillGuard = {
            stateAtWillGuard = subject.coordinator.state
        }

        subject.coordinator.startCountdown()
        subject.coordinator.startCountdown()
        subject.coordinator.startNow()
        subject.coordinator.startNow()
        subject.coordinator.startCountdown()

        #expect(subject.coordinator.state == .guarded)
        #expect(stateAtWillGuard == .arming)
        #expect(subject.windows.prepareCallCount == 1)
        #expect(subject.input.preflightCallCount == 2)
        #expect(subject.log.entries == [
            "auth.available",
            "input.preflight",
            "auth.available",
            "input.preflight",
            "power.create.system",
            "windows.prepare",
            "input.start.full",
            "presentation.begin",
            "windows.present",
        ])
    }

    @Test("An in-flight scene change prevents Away activation before owned resources")
    func sceneMutationBlocksActivation() throws {
        let subject = AwayCoordinatorHarness()
        let scenePermit = try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)

        subject.coordinator.startCountdown()
        subject.coordinator.startNow()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.mutationInProgress.message)
        #expect(subject.backend.activeIDs.isEmpty)
        #expect(subject.windows.prepareCallCount == 0)
        #expect(!subject.input.isActive)
        #expect(subject.mutationAdmission.activeExclusiveOwner == nil)
        #expect(subject.mutationAdmission.release(scenePermit))
    }

    @Test("Away holds exclusive admission through authentication and releases after exit")
    func exclusiveAdmissionLifecycle() async throws {
        let subject = AwayCoordinatorHarness()
        subject.authenticator.plans = [.init(succeeds: true, yieldCount: 2)]
        subject.enterGuarded()

        #expect(subject.mutationAdmission.activeExclusiveOwner == .awayMode)
        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)
        }

        subject.coordinator.requestAuthentication()
        #expect(subject.coordinator.isAuthenticating)
        #expect(subject.mutationAdmission.activeExclusiveOwner == .awayMode)
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.mutationAdmission.activeExclusiveOwner == nil)
        let scenePermit = try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)
        #expect(subject.mutationAdmission.release(scenePermit))
    }

    @Test("Activation rollback releases exclusive admission")
    func rollbackReleasesExclusiveAdmission() throws {
        let subject = AwayCoordinatorHarness()
        subject.input.startResult = false

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.mutationAdmission.activeExclusiveOwner == nil)
        let scenePermit = try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)
        #expect(subject.mutationAdmission.release(scenePermit))
    }

    @Test("Capability failures never begin activation")
    func capabilityFailures() {
        let missingBuilder = AwayCoordinatorHarness()
        missingBuilder.coordinator.makeCurtainContent = nil
        missingBuilder.coordinator.startCountdown()
        #expect(missingBuilder.coordinator.state == .inactive)
        #expect(missingBuilder.coordinator.lastErrorMessage == AwayModeActivationError.panelPreparationFailed.message)

        let disclosure = AwayCoordinatorHarness(disclosureCompleted: false)
        disclosure.coordinator.startCountdown()
        #expect(disclosure.coordinator.state == .inactive)
        #expect(disclosure.coordinator.lastErrorMessage == AwayModeActivationError.disclosureRequired.message)

        let unavailableAuth = AwayCoordinatorHarness()
        unavailableAuth.authenticator.available = false
        unavailableAuth.coordinator.startCountdown()
        #expect(unavailableAuth.coordinator.state == .inactive)
        #expect(unavailableAuth.coordinator.lastErrorMessage == AwayModeActivationError.systemAuthenticationUnavailable.message)

        let missingPIN = AwayCoordinatorHarness(authenticationMethod: .pin)
        missingPIN.pinStore.hasStoredPIN = false
        missingPIN.coordinator.startCountdown()
        #expect(missingPIN.coordinator.state == .inactive)
        #expect(missingPIN.coordinator.lastErrorMessage == AwayModeActivationError.pinMissingOrUnreadable.message)

        let unreadablePIN = AwayCoordinatorHarness(authenticationMethod: .pin)
        unreadablePIN.pinStore.hasPINError = AwayCoordinatorTestError.expected
        unreadablePIN.coordinator.startCountdown()
        #expect(unreadablePIN.coordinator.state == .inactive)
        #expect(unreadablePIN.coordinator.lastErrorMessage == AwayModeActivationError.pinMissingOrUnreadable.message)

        let deniedInput = AwayCoordinatorHarness()
        deniedInput.input.preflightResult = false
        deniedInput.coordinator.startCountdown()
        #expect(deniedInput.coordinator.state == .inactive)
        #expect(deniedInput.coordinator.lastErrorMessage == AwayModeActivationError.eventAccessRequired.message)

        for subject in [missingBuilder, disclosure, unavailableAuth, missingPIN, unreadablePIN, deniedInput] {
            #expect(subject.backend.activeIDs.isEmpty)
            #expect(subject.windows.prepareCallCount == 0)
        }
    }

    @Test("Power acquisition failure rolls back without presenting")
    func powerFailureRollback() {
        let subject = AwayCoordinatorHarness()
        subject.backend.failingKinds = [.preventIdleSystemSleep]

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.powerAssertionFailed.message)
        #expect(Array(subject.log.entries.suffix(4)) == [
            "power.create.system",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
        ])
        #expect(subject.backend.activeIDs.isEmpty)
    }

    @Test("Failed power rollback holds admission until owned cleanup succeeds")
    func powerRollbackCleanupOwnership() throws {
        let subject = AwayCoordinatorHarness(keepsDisplayAwake: true)
        subject.backend.failingKinds = [.preventIdleDisplaySleep]
        subject.backend.failingReleaseIDs = [1]

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == "\(AwayModeActivationError.powerAssertionFailed.message) The macOS awake request cleanup is still pending.")
        #expect(subject.awakeService.hasPendingLeaseCleanup(owner: .awayMode))
        #expect(subject.backend.activeIDs == [1])
        #expect(subject.mutationAdmission.activeExclusiveOwner == .awayMode)
        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)
        }

        subject.backend.failingKinds = []
        subject.backend.failingReleaseIDs = []
        subject.coordinator.startCountdown()

        #expect(subject.coordinator.state == .countdown(remainingSeconds: 5))
        #expect(!subject.awakeService.hasPendingLeaseCleanup(owner: .awayMode))
        #expect(subject.backend.activeIDs.isEmpty)
        #expect(subject.mutationAdmission.activeExclusiveOwner == nil)
        subject.coordinator.cancelCountdown()
    }

    @Test("Panel preparation failure rolls back in reverse order")
    func preparationFailureRollback() {
        let subject = AwayCoordinatorHarness()
        subject.windows.preparationResult = .failed(.panelCreationFailed)

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.panelPreparationFailed.message)
        #expect(Array(subject.log.entries.suffix(6)) == [
            "power.create.system",
            "windows.prepare",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
    }

    @Test("Input filter failure rolls back in reverse order")
    func inputFailureRollback() {
        let subject = AwayCoordinatorHarness()
        subject.input.startResult = false

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.inputFilterFailed.message)
        #expect(Array(subject.log.entries.suffix(7)) == [
            "power.create.system",
            "windows.prepare",
            "input.start.full",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
    }

    @Test("Presentation failure rolls back in reverse order")
    func presentationFailureRollback() {
        let subject = AwayCoordinatorHarness()
        subject.presentation.beginFails = true

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.presentationFailed.message)
        #expect(Array(subject.log.entries.suffix(8)) == [
            "power.create.system",
            "windows.prepare",
            "input.start.full",
            "presentation.begin",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
    }

    @Test("Coverage failure rolls back in reverse order")
    func coverageFailureRollback() {
        let subject = AwayCoordinatorHarness()
        subject.windows.presentationResult = .failed(.coverageVerificationFailed)

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.coverageFailed.message)
        #expect(Array(subject.log.entries.suffix(9)) == [
            "power.create.system",
            "windows.prepare",
            "input.start.full",
            "presentation.begin",
            "windows.present",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
    }

    @Test("Filtering loss during panel presentation rolls back activation")
    func filteringLossDuringPresentationRollsBack() {
        let subject = AwayCoordinatorHarness()
        subject.windows.onPresent = {
            subject.input.isFilteringOperational = false
        }

        subject.enterGuarded()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.inputFilterFailed.message)
        #expect(!subject.windows.isPresented)
        #expect(subject.backend.activeIDs.isEmpty)
    }

    @Test("System authentication exits while keeping panels through restoration")
    func successfulSystemExit() async {
        let subject = AwayCoordinatorHarness()
        var didDisarm = false
        subject.coordinator.onDidDisarm = { didDisarm = true }
        subject.enterGuarded()

        subject.coordinator.requestAuthentication()
        #expect(subject.coordinator.isAuthenticating)
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(didDisarm)
        #expect(subject.backend.activeIDs.isEmpty)
        #expect(Array(subject.log.entries.suffix(7)) == [
            "auth.authenticate",
            "input.policy.full",
            "input.recover",
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
        let dismissIndex = subject.log.entries.lastIndex(of: "windows.dismiss")
        let filteringIndex = subject.log.entries.lastIndex(of: "input.stop")
        #expect((dismissIndex ?? Int.max) < (filteringIndex ?? Int.min))
    }

    @Test("A stale authentication result cannot exit a newer session")
    func staleAuthenticationResult() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.coordinator.requestAuthentication()
        guard case .authenticating(let firstAttemptID) = subject.coordinator.state else {
            Issue.record("Expected the first authentication attempt")
            return
        }
        #expect(subject.coordinator.completeSystemAuthentication(
            succeeded: false,
            attemptID: firstAttemptID
        ))

        subject.coordinator.requestAuthentication()
        guard case .authenticating(let secondAttemptID) = subject.coordinator.state else {
            Issue.record("Expected the second authentication attempt")
            return
        }
        #expect(secondAttemptID != firstAttemptID)

        #expect(!subject.coordinator.completeSystemAuthentication(
            succeeded: true,
            attemptID: firstAttemptID
        ))

        #expect(subject.coordinator.state == .authenticating(attemptID: secondAttemptID))
        #expect(subject.windows.isPresented)
        #expect(subject.awakeService.hasLease(for: .awayMode))
        subject.coordinator.shutdown()
    }

    @Test("Successful Mac authentication exits even when input filtering cannot recover")
    func successfulSystemAuthenticationRecoversFromInputFailure() async {
        let subject = AwayCoordinatorHarness()
        subject.authenticator.plans = [.init(succeeds: true, yieldCount: 10_000)]
        subject.enterGuarded()
        subject.coordinator.requestAuthentication()
        guard case .authenticating(let attemptID) = subject.coordinator.state else {
            Issue.record("Expected system authentication")
            return
        }
        subject.input.isFilteringOperational = false

        #expect(subject.coordinator.completeSystemAuthentication(
            succeeded: true,
            attemptID: attemptID
        ))
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(!subject.windows.isPresented)
        #expect(!subject.awakeService.hasLease(for: .awayMode))
    }

    @Test("Wrong PIN attempts cool down and a correct PIN exits")
    func pinCooldownAndSuccess() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.enterGuarded()
        subject.coordinator.requestAuthentication()
        #expect(subject.input.policies.last == .pinEntry)

        for _ in 0..<5 {
            subject.coordinator.updatePINEntry("9999")
            subject.coordinator.submitPIN()
            await settle()
        }
        #expect(subject.coordinator.pinCooldown.failureCount == 5)
        #expect(subject.coordinator.cooldownRemaining == 30)
        #expect(subject.pinStore.verifiedCandidates.count == 5)

        subject.coordinator.updatePINEntry("0123")
        subject.coordinator.appendPINDigit(7)
        subject.coordinator.deleteLastPINDigit()
        #expect(subject.coordinator.pinEntry.isEmpty)
        subject.coordinator.submitPIN()
        #expect(subject.pinStore.verifiedCandidates.count == 5)
        #expect(subject.coordinator.state != .inactive)

        subject.clock.advance(30)
        subject.coordinator.updatePINEntry("9999")
        subject.coordinator.submitPIN()
        await settle()
        #expect(subject.coordinator.pinCooldown.failureCount == 6)
        #expect(subject.coordinator.cooldownRemaining == 60)

        subject.clock.advance(60)
        subject.coordinator.updatePINEntry("0123")
        subject.coordinator.submitPIN()
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.pinCooldown.failureCount == 0)
        #expect(subject.coordinator.cooldownRemaining == 0)
    }

    @Test("PIN entry cannot change while verification is running")
    func pinEntryIsFrozenDuringVerification() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        let verificationGate = DispatchSemaphore(value: 0)
        subject.pinStore.allowVerificationToFinish = verificationGate
        subject.enterGuarded()
        subject.coordinator.requestAuthentication()
        subject.coordinator.updatePINEntry("0123")

        subject.coordinator.submitPIN()
        #expect(subject.coordinator.isVerifyingPIN)
        subject.coordinator.updatePINEntry("9999")
        subject.coordinator.appendPINDigit(7)
        subject.coordinator.deleteLastPINDigit()
        #expect(subject.coordinator.pinEntry.isEmpty)

        verificationGate.signal()
        await settle()
        #expect(subject.coordinator.state == .inactive)
    }

    @Test("PIN recovery presents system authentication then returns to PIN")
    func pinRecoveryAuthenticationPresentation() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.authenticator.plans = [.init(succeeds: false, yieldCount: 0)]
        subject.enterGuarded()
        subject.coordinator.requestAuthentication()
        #expect(subject.coordinator.activeAuthenticationMethod == .pin)

        subject.coordinator.beginSystemAuthentication()
        #expect(subject.coordinator.activeAuthenticationMethod == .system)
        await settle()

        #expect(subject.coordinator.activeAuthenticationMethod == .pin)
        #expect(subject.coordinator.isAuthenticating)
        #expect(Array(subject.input.policies.suffix(3)) == [
            .systemAuthentication,
            .fullFiltering,
            .pinEntry,
        ])
    }

    @Test("PIN entry stays unavailable when input filtering cannot recover")
    func pinEntryRequiresFilteringRecovery() {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.enterGuarded()
        subject.input.sendFailure()

        subject.coordinator.requestAuthentication()

        #expect(subject.coordinator.activeAuthenticationMethod == nil)
        #expect(subject.coordinator.state == .degraded(
            message: "Input filtering stopped. Use Mac authentication or Force Quit."
        ))
        #expect(subject.input.policies.last == .pinEntry)
    }

    @Test("Quit callback runs only after successful authentication")
    func authenticatedQuit() async {
        let subject = AwayCoordinatorHarness()
        subject.authenticator.plans = [
            .init(succeeds: false, yieldCount: 0),
            .init(succeeds: true, yieldCount: 0),
        ]
        var quitCallCount = 0
        subject.coordinator.onAuthenticatedQuit = { quitCallCount += 1 }
        subject.enterGuarded()

        subject.coordinator.requestQuit()
        await settle()
        #expect(subject.coordinator.state == .guarded)
        #expect(quitCallCount == 0)

        subject.coordinator.requestQuit()
        await settle()
        #expect(subject.coordinator.state == .inactive)
        #expect(quitCallCount == 1)
    }

    @Test("Quit requested while arming authenticates after coverage is active")
    func quitDuringArmingIsQueued() async {
        let subject = AwayCoordinatorHarness()
        var quitCallCount = 0
        subject.coordinator.onAuthenticatedQuit = { quitCallCount += 1 }
        subject.windows.onPresent = {
            subject.coordinator.requestQuit()
        }

        subject.enterGuarded()
        #expect(subject.coordinator.isAuthenticating)
        #expect(subject.windows.isPresented)

        await settle()
        #expect(subject.coordinator.state == .inactive)
        #expect(quitCallCount == 1)
    }

    @Test("Quit during active authentication keeps the original attempt and exits after success")
    func quitDuringAuthentication() async {
        let subject = AwayCoordinatorHarness()
        var quitCallCount = 0
        subject.coordinator.onAuthenticatedQuit = { quitCallCount += 1 }
        subject.enterGuarded()

        subject.coordinator.requestAuthentication()
        subject.coordinator.requestQuit()
        await settle()

        #expect(subject.authenticator.reasons == ["Exit Semper Away Mode."])
        #expect(subject.coordinator.state == .inactive)
        #expect(quitCallCount == 1)
    }

    @Test("Quit during authenticated disarming waits for cleanup")
    func quitDuringDisarming() async {
        let disarmGate = AwayCoordinatorDisarmGate()
        let subject = AwayCoordinatorHarness(sleep: { duration in
            try await disarmGate.sleep(duration)
        })
        var quitCallCount = 0
        subject.coordinator.onAuthenticatedQuit = { quitCallCount += 1 }
        subject.enterGuarded()

        subject.coordinator.requestAuthentication()
        await settle()
        #expect(subject.coordinator.state == .disarming)

        subject.coordinator.requestQuit()
        #expect(quitCallCount == 0)
        await disarmGate.open()
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(quitCallCount == 1)
    }

    @Test("Command Q input requests authentication and quits after success")
    func inputQuitRequest() async {
        let subject = AwayCoordinatorHarness()
        var quitCallCount = 0
        subject.coordinator.onAuthenticatedQuit = { quitCallCount += 1 }
        subject.enterGuarded()

        subject.input.sendQuitRequest()
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(quitCallCount == 1)
    }

    @Test("Authenticated Quit resumes deferred update only after Away cleanup")
    func authenticatedQuitOrdering() async {
        let subject = AwayCoordinatorHarness()
        var events: [String] = []
        let updateDeferral = UpdateInstallationDeferral()
        updateDeferral.shouldDefer = { subject.coordinator.isGuarding }
        let delegate = AppDelegate(terminateApplication: {
            events.append("application.terminate")
        })
        delegate.awayMode = subject.coordinator
        subject.coordinator.onDidDisarm = {
            events.append("away.cleanup.complete")
            updateDeferral.resume()
        }
        subject.coordinator.onAuthenticatedQuit = {
            events.append("away.authenticated.quit")
            delegate.permitTerminationAfterAwayAuthentication()
        }
        subject.enterGuarded()
        #expect(updateDeferral.postpone {
            events.append("update.resume")
        })

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(reply == .terminateCancel)
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(events == [
            "away.cleanup.complete",
            "update.resume",
            "away.authenticated.quit",
            "application.terminate",
        ])
        #expect(Array(subject.log.entries.suffix(4)) == [
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
        ])
    }

    @Test("Creating a PIN requires Mac authentication and updates preferences")
    func configurePIN() async {
        let subject = AwayCoordinatorHarness()

        let configured = await subject.coordinator.configurePIN(
            "0123",
            confirmation: "0123"
        )

        #expect(configured)
        #expect(subject.pinStore.preparedPINs == ["0123"])
        #expect(subject.pinStore.storedPINs == ["0123"])
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(subject.authenticator.reasons == ["Change the Semper Away Mode PIN."])
    }

    @Test("Shutdown during PIN preparation prevents the Keychain commit")
    func configurePINShutdownBeforeCommit() async {
        let subject = AwayCoordinatorHarness()
        let allowPreparationToFinish = DispatchSemaphore(value: 0)
        subject.pinStore.allowPreparationToFinish = allowPreparationToFinish
        let configuration = Task { @MainActor in
            await subject.coordinator.configurePIN("0123", confirmation: "0123")
        }

        var didStartPreparation = false
        for _ in 0..<1_000 {
            if subject.pinStore.didStartPreparation {
                didStartPreparation = true
                break
            }
            await Task.yield()
        }
        #expect(didStartPreparation)

        subject.coordinator.shutdown()
        allowPreparationToFinish.signal()

        #expect(!(await configuration.value))
        #expect(subject.pinStore.storedPINs.isEmpty)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
    }

    @Test("PIN confirmation mismatch never starts Mac authentication")
    func configurePINConfirmationMismatch() async {
        let subject = AwayCoordinatorHarness()

        let configured = await subject.coordinator.configurePIN(
            "0123",
            confirmation: "0124"
        )

        #expect(!configured)
        #expect(subject.pinStore.storedPINs.isEmpty)
        #expect(subject.authenticator.reasons.isEmpty)
        #expect(subject.coordinator.pinConfigurationError == "PIN entries do not match.")
    }

    @Test("PIN creation reports a settings persistence failure")
    func configurePINPersistenceFailure() async {
        let subject = AwayCoordinatorHarness(
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )

        let configured = await subject.coordinator.configurePIN(
            "0123",
            confirmation: "0123"
        )

        #expect(!configured)
        #expect(subject.pinStore.storedPINs == ["0123"])
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(
            subject.coordinator.pinConfigurationError
                == "The PIN was stored, but Away Mode settings could not be saved. Review setup before starting."
        )
    }

    @Test("Removing a PIN requires Mac authentication and restores system authentication")
    func removePIN() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)

        let removed = await subject.coordinator.removePIN()

        #expect(removed)
        #expect(subject.pinStore.removeCallCount == 1)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(subject.authenticator.reasons == ["Remove the Semper Away Mode PIN."])
    }

    @Test("PIN deletion and authentication preference repair stay atomic across shutdown")
    func removePINShutdownDuringCommit() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        let allowRemovalToFinish = DispatchSemaphore(value: 0)
        subject.pinStore.allowRemovalToFinish = allowRemovalToFinish
        let coordinator = subject.coordinator
        let pinStore = subject.pinStore
        let releaseAndShutdown = Task.detached {
            var didStartRemoval = false
            for _ in 0..<10_000 {
                if pinStore.didStartRemoval {
                    didStartRemoval = true
                    break
                }
                await Task.yield()
            }
            let shutdown = Task { @MainActor in
                coordinator.shutdown()
            }
            try? await Task.sleep(for: .milliseconds(50))
            allowRemovalToFinish.signal()
            await shutdown.value
            return didStartRemoval
        }

        let removed = await coordinator.removePIN()

        #expect(removed)
        #expect(await releaseAndShutdown.value)
        #expect(!subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
    }

    @Test("PIN removal reports a settings persistence failure")
    func removePINPersistenceFailure() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )

        let removed = await subject.coordinator.removePIN()

        #expect(!removed)
        #expect(!subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(
            subject.coordinator.pinConfigurationError
                == "The PIN was removed, but Away Mode settings could not be saved. Repair setup after relaunch."
        )
    }

    @Test("Setup applies the captured submission after held PIN removal")
    func setupUsesCapturedSubmission() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        subject.authenticator.plans = [.init(succeeds: true, yieldCount: 10_000)]
        var authenticationMethod = AwayAuthenticationMethod.system
        var theme = AwayModeTheme.quietOrbits
        var accent = AwayModeAccent.amber
        var pinDraft = AwayPINSetupDraft()
        pinDraft.setPIN("0123")
        pinDraft.setConfirmation("0123")
        let submission = AwaySetupSubmission(
            authenticationMethod: authenticationMethod,
            theme: theme,
            accent: accent,
            pin: pinDraft.pin,
            confirmation: pinDraft.confirmation,
            existingAuthenticationMethod: .pin
        )
        let save = Task { @MainActor in
            await submission.apply(to: subject.coordinator)
        }
        for _ in 0..<100 where subject.authenticator.reasons.isEmpty {
            await Task.yield()
        }

        authenticationMethod = .pin
        theme = .aurora
        accent = .blue
        pinDraft.setPIN("9876")
        pinDraft.setConfirmation("9876")

        #expect(await save.value)
        #expect(!subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(subject.coordinator.preferences.theme == .quietOrbits)
        #expect(subject.coordinator.preferences.accent == .amber)
        #expect(subject.coordinator.preferences.disclosureCompleted)
    }

    @Test("Setup can keep a readable existing PIN without replacing it")
    func setupKeepsExistingPIN() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        let submission = AwaySetupSubmission(
            authenticationMethod: .pin,
            theme: .quietOrbits,
            accent: .amber,
            pin: "",
            confirmation: "",
            existingAuthenticationMethod: .pin,
            existingPINIsUsable: true
        )

        #expect(await submission.apply(to: subject.coordinator))
        #expect(subject.authenticator.reasons.isEmpty)
        #expect(subject.pinStore.preparedPINs.isEmpty)
        #expect(subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(subject.coordinator.preferences.theme == .quietOrbits)
        #expect(subject.coordinator.preferences.accent == .amber)
        #expect(subject.coordinator.preferences.disclosureCompleted)
    }

    @Test("A captured setup cannot restore a PIN selection after PIN removal")
    func setupRejectsStaleRetainedPIN() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        let submission = AwaySetupSubmission(
            authenticationMethod: .pin,
            theme: .quietOrbits,
            accent: .amber,
            pin: "",
            confirmation: "",
            existingAuthenticationMethod: .pin,
            existingPINIsUsable: true
        )

        #expect(await subject.coordinator.removePIN())
        #expect(!(await submission.apply(to: subject.coordinator)))
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(!subject.coordinator.preferences.disclosureCompleted)
        #expect(subject.coordinator.pinConfigurationError == "The existing PIN is missing. Create a new PIN.")
    }

    @Test("Setup rechecks a retained PIN for readable storage")
    func setupRejectsUnreadableRetainedPIN() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        let submission = AwaySetupSubmission(
            authenticationMethod: .pin,
            theme: .quietOrbits,
            accent: .amber,
            pin: "",
            confirmation: "",
            existingAuthenticationMethod: .pin,
            existingPINIsUsable: true
        )
        subject.pinStore.hasPINError = AwayCoordinatorTestError.expected

        #expect(!(await submission.apply(to: subject.coordinator)))
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(!subject.coordinator.preferences.disclosureCompleted)
        #expect(
            subject.coordinator.pinConfigurationError
                == "The existing PIN could not be read. Create a new PIN."
        )
    }

    @Test("Setup cannot commit after coordinator shutdown")
    func setupRejectsShutdown() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        let submission = AwaySetupSubmission(
            authenticationMethod: .pin,
            theme: .quietOrbits,
            accent: .amber,
            pin: "",
            confirmation: "",
            existingAuthenticationMethod: .pin,
            existingPINIsUsable: true
        )
        subject.coordinator.shutdown()

        #expect(!(await submission.apply(to: subject.coordinator)))
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(!subject.coordinator.preferences.disclosureCompleted)
        #expect(subject.coordinator.pinConfigurationError == "Away Mode setup can no longer be saved.")
    }

    @Test("Setup persistence failure restores prior preferences")
    func setupPersistenceFailureRestoresPreferences() {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false,
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )
        let priorPreferences = subject.coordinator.preferences

        let saved = subject.coordinator.finishSetup(
            authenticationMethod: .system,
            theme: .quietOrbits,
            accent: .amber
        )

        #expect(!saved)
        #expect(subject.coordinator.preferences == priorPreferences)
        #expect(!subject.coordinator.preferences.disclosureCompleted)
        #expect(subject.coordinator.pinConfigurationError == "Away Mode setup could not be saved.")
    }

    @Test("Canceling the owned setup save leaves a held PIN removal uncommitted")
    func setupCancellationStopsHeldPINRemoval() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            disclosureCompleted: false
        )
        subject.authenticator.plans = [.init(succeeds: true, yieldCount: 10_000)]
        let submission = AwaySetupSubmission(
            authenticationMethod: .system,
            theme: .quietOrbits,
            accent: .amber,
            pin: "",
            confirmation: "",
            existingAuthenticationMethod: .pin
        )
        let save = Task { @MainActor in
            await submission.apply(to: subject.coordinator)
        }
        for _ in 0..<100 where subject.authenticator.reasons.isEmpty {
            await Task.yield()
        }

        save.cancel()

        #expect(!(await save.value))
        #expect(subject.pinStore.removeCallCount == 0)
        #expect(subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(!subject.coordinator.preferences.disclosureCompleted)
    }

    @Test("Photo replacement stays successful when the prior managed copy cannot be removed")
    func photoReplacementCleanupFailure() throws {
        let priorFilename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let sourceURL = URL(fileURLWithPath: "/tmp/new-away-photo.jpg")
        let subject = AwayCoordinatorHarness()
        subject.photoStore.removeError = AwayCoordinatorTestError.expected
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = priorFilename
            $0.theme = .customPhoto
        }

        let imported = try subject.coordinator.importPhoto(from: sourceURL)

        #expect(imported == subject.photoStore.importedPhoto)
        #expect(subject.photoStore.importedSourceURLs == [sourceURL])
        #expect(subject.photoStore.removalAttempts == [priorFilename])
        #expect(subject.photoStore.removedFilenames.isEmpty)
        #expect(
            subject.coordinator.preferences.managedPhotoFilename
                == subject.photoStore.importedPhoto.filename
        )
        #expect(subject.coordinator.preferences.theme == .customPhoto)
    }

    @Test("Photo replacement keeps the prior reference when settings cannot be persisted")
    func photoReplacementPersistenceFailure() {
        let priorFilename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let sourceURL = URL(fileURLWithPath: "/tmp/new-away-photo.jpg")
        let subject = AwayCoordinatorHarness(
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = priorFilename
            $0.theme = .customPhoto
        }

        do {
            _ = try subject.coordinator.importPhoto(from: sourceURL)
            Issue.record("Expected settings persistence to fail")
        } catch {
            #expect(error as? AwayModeDataError == .persistenceFailed)
        }

        #expect(subject.coordinator.preferences.managedPhotoFilename == priorFilename)
        #expect(subject.coordinator.preferences.theme == .customPhoto)
        #expect(subject.photoStore.removalAttempts == [subject.photoStore.importedPhoto.filename])
        #expect(subject.photoStore.removedFilenames == [subject.photoStore.importedPhoto.filename])
    }

    @Test("Photo persistence failure reports failed imported-copy cleanup")
    func photoReplacementPersistenceAndCleanupFailure() {
        let priorFilename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let sourceURL = URL(fileURLWithPath: "/tmp/new-away-photo.jpg")
        let subject = AwayCoordinatorHarness(
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )
        subject.photoStore.removeError = AwayCoordinatorTestError.expected
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = priorFilename
            $0.theme = .customPhoto
        }

        do {
            _ = try subject.coordinator.importPhoto(from: sourceURL)
            Issue.record("Expected settings persistence and photo cleanup to fail")
        } catch {
            #expect(error as? AwayModeDataError == .persistenceAndCleanupFailed)
        }

        #expect(subject.coordinator.preferences.managedPhotoFilename == priorFilename)
        #expect(subject.photoStore.removalAttempts == [subject.photoStore.importedPhoto.filename])
        #expect(subject.photoStore.removedFilenames.isEmpty)
    }

    @Test("Reset authenticates, deletes Away data, and repairs its persisted references")
    func resetAwayData() async throws {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
            $0.theme = .customPhoto
        }

        try await subject.coordinator.resetAwayData()

        #expect(subject.authenticator.reasons == ["Reset Semper settings and delete Away Mode data."])
        #expect(subject.pinStore.removeCallCount == 1)
        #expect(subject.photoStore.removedFilenames == [
            "away-photo-00000000-0000-0000-0000-000000000000.jpg",
        ])
        #expect(subject.photoStore.cleanupCallCount == 2)
        #expect(subject.photoStore.cleanupKeptFilenames[1] == nil)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(subject.coordinator.preferences.managedPhotoFilename == nil)
        #expect(subject.coordinator.preferences.theme == .aurora)
    }

    @Test("Reset is rejected while Away Mode is guarding")
    func guardedResetRejected() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.enterGuarded()

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected guarded reset to be rejected")
        } catch {
            #expect(error as? AwayModeDataError == .mutationUnavailable)
        }
        #expect(subject.pinStore.removeCallCount == 0)
        #expect(subject.photoStore.cleanupCallCount == 1)
    }

    @Test("Failed Reset authentication deletes nothing")
    func resetAuthenticationFailure() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.authenticator.plans = [.init(succeeds: false, yieldCount: 0)]
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
            $0.theme = .customPhoto
        }

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected Reset authentication to fail")
        } catch {
            #expect(error as? AwayModeDataError == .authenticationFailed)
        }

        #expect(subject.pinStore.removeCallCount == 0)
        #expect(subject.photoStore.removedFilenames.isEmpty)
        #expect(subject.photoStore.cleanupCallCount == 1)
        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(subject.coordinator.preferences.managedPhotoFilename != nil)
        #expect(subject.coordinator.preferences.theme == .customPhoto)
    }

    @Test("Partial Reset keeps preferences aligned with completed deletions")
    func partialResetPreferenceRepair() async {
        let filename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.photoStore.removeError = AwayCoordinatorTestError.expected
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = filename
            $0.theme = .customPhoto
        }

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected managed photo deletion to fail")
        } catch {
            #expect(error as? AwayModeDataError == .deletionFailed(
                completed: [.pin, .unusedPhotos],
                failed: [.managedPhoto]
            ))
        }

        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(subject.coordinator.preferences.managedPhotoFilename == filename)
        #expect(subject.coordinator.preferences.theme == .customPhoto)
        #expect(subject.photoStore.cleanupKeptFilenames.last == filename)
    }

    @Test("Photo deletion repairs its preferences even when PIN deletion fails")
    func partialResetPhotoSuccess() async {
        let filename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.pinStore.removeError = AwayCoordinatorTestError.expected
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = filename
            $0.theme = .customPhoto
        }

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected PIN deletion to fail")
        } catch {
            #expect(error as? AwayModeDataError == .deletionFailed(
                completed: [.managedPhoto, .unusedPhotos],
                failed: [.pin]
            ))
        }

        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(subject.coordinator.preferences.managedPhotoFilename == nil)
        #expect(subject.coordinator.preferences.theme == .aurora)
        #expect(subject.photoStore.cleanupKeptFilenames[1] == nil)
    }

    @Test("Reset reports unused photo cleanup failure after repairing other data")
    func resetUnusedPhotoCleanupFailure() async {
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.photoStore.cleanupError = AwayCoordinatorTestError.expected

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected unused photo cleanup to fail")
        } catch {
            #expect(error as? AwayModeDataError == .deletionFailed(
                completed: [.pin],
                failed: [.unusedPhotos]
            ))
        }

        #expect(subject.coordinator.preferences.authenticationMethod == .system)
        #expect(subject.pinStore.removeCallCount == 1)
        #expect(subject.photoStore.cleanupCallCount == 2)
    }

    @Test("Reset reports settings persistence failure after local data deletion")
    func resetPersistenceFailure() async {
        let subject = AwayCoordinatorHarness(
            authenticationMethod: .pin,
            persistenceWriter: SettingsPersistenceWriter { _, _ in
                throw AwayCoordinatorTestError.expected
            }
        )

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected reset persistence to fail")
        } catch {
            #expect(error as? AwayModeDataError == .deletionFailed(
                completed: [.pin, .unusedPhotos],
                failed: [.settings]
            ))
        }

        #expect(!subject.pinStore.hasStoredPIN)
        #expect(subject.coordinator.preferences.authenticationMethod == .system)
    }

    @Test("Reset reports every independent deletion failure")
    func resetMultipleDeletionFailures() async {
        let filename = "away-photo-00000000-0000-0000-0000-000000000000.jpg"
        let subject = AwayCoordinatorHarness(authenticationMethod: .pin)
        subject.pinStore.removeError = AwayCoordinatorTestError.expected
        subject.photoStore.removeError = AwayCoordinatorTestError.expected
        subject.photoStore.cleanupError = AwayCoordinatorTestError.expected
        subject.coordinator.updatePreferences {
            $0.managedPhotoFilename = filename
            $0.theme = .customPhoto
        }

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected every Away data deletion to fail")
        } catch {
            #expect(error as? AwayModeDataError == .deletionFailed(
                completed: [],
                failed: [.pin, .managedPhoto, .unusedPhotos]
            ))
        }

        #expect(subject.coordinator.preferences.authenticationMethod == .pin)
        #expect(subject.coordinator.preferences.managedPhotoFilename == filename)
        #expect(subject.coordinator.preferences.theme == .customPhoto)
        #expect(subject.photoStore.removalAttempts == [filename])
    }

    @Test("Reset cannot race PIN creation")
    func resetDuringPINCreation() async {
        let subject = AwayCoordinatorHarness()
        subject.authenticator.plans = [.init(succeeds: true, yieldCount: 20)]
        let configuration = Task { @MainActor in
            await subject.coordinator.configurePIN("0123", confirmation: "0123")
        }
        for _ in 0..<20 where !subject.coordinator.isManagingPIN {
            await Task.yield()
        }
        #expect(subject.coordinator.isManagingPIN)

        do {
            try await subject.coordinator.resetAwayData()
            Issue.record("Expected Reset to be rejected during PIN creation")
        } catch {
            #expect(error as? AwayModeDataError == .mutationUnavailable)
        }
        #expect(subject.pinStore.removeCallCount == 0)
        #expect(await configuration.value)
        #expect(subject.pinStore.storedPINs == ["0123"])
    }

    @Test("Repeated activity coalesces dim timer replacement")
    func activityCoalescesDimTimers() async {
        let sleepProbe = AwayCoordinatorSleepProbe()
        let dimDelay = Duration.seconds(300)
        let subject = AwayCoordinatorHarness(
            keepsDisplayAwake: true,
            sleep: { duration in try await sleepProbe.sleep(duration) }
        )
        subject.enterGuarded()
        for _ in 0..<1_000 {
            if await sleepProbe.callCount(for: dimDelay) > 0 { break }
            await Task.yield()
        }
        let initialSleepCallCount = await sleepProbe.callCount(for: dimDelay)
        #expect(initialSleepCallCount == 1)

        for _ in 0..<1_000 {
            subject.input.sendActivity()
        }
        await Task.yield()
        let coalescedSleepCallCount = await sleepProbe.callCount(for: dimDelay)
        #expect(coalescedSleepCallCount == 1)

        subject.clock.advance(1)
        subject.input.sendActivity()
        for _ in 0..<1_000 {
            if await sleepProbe.callCount(for: dimDelay) >= 2 { break }
            await Task.yield()
        }
        let rescheduledSleepCallCount = await sleepProbe.callCount(for: dimDelay)
        #expect(rescheduledSleepCallCount == 2)
        subject.coordinator.shutdown()
    }

    @Test("Critical power releases the lease and recovery reacquires it")
    func powerRestrictionAndRecovery() {
        let subject = AwayCoordinatorHarness(keepsDisplayAwake: true)
        subject.enterGuarded()
        #expect(subject.backend.activeIDs.count == 2)

        subject.powerSource.reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .critical,
            powerSupply: .battery(percentage: 80)
        )
        subject.powerSource.sendChange()

        #expect(subject.backend.activeIDs.isEmpty)
        #expect(!subject.awakeService.hasLease(for: .awayMode))
        #expect(subject.coordinator.powerWarning?.contains("macOS may sleep") == true)

        subject.powerSource.reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            powerSupply: .ac(percentage: 80, isCharging: true)
        )
        subject.powerSource.sendChange()

        #expect(subject.backend.activeIDs.count == 2)
        #expect(subject.awakeService.hasLease(for: .awayMode))
        #expect(subject.coordinator.powerWarning == nil)
    }

    @Test("Failed Away lease release remains pending for shutdown cleanup")
    func failedLeaseReleaseRemainsPending() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.backend.failingReleaseIDs = [1]
        subject.powerSource.reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .critical,
            powerSupply: .battery(percentage: 80)
        )

        subject.powerSource.sendChange()

        #expect(subject.backend.activeIDs == [1])
        #expect(subject.coordinator.powerWarning == "The macOS awake request cleanup is pending.")
        subject.coordinator.shutdown()
        subject.backend.failingReleaseIDs = []
        subject.awakeService.shutdown()
        #expect(subject.backend.activeIDs.isEmpty)
    }

    @Test("Safe power recovery cleans a stale lease before reacquiring")
    func safePowerRecoveryAfterFailedRelease() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.backend.failingReleaseIDs = [1]
        subject.powerSource.reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .critical,
            powerSupply: .battery(percentage: 80)
        )
        subject.powerSource.sendChange()

        #expect(!subject.awakeService.hasLease(for: .awayMode))
        #expect(subject.backend.activeIDs == [1])

        subject.backend.failingReleaseIDs = []
        subject.powerSource.reading = AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            powerSupply: .ac(percentage: 80, isCharging: true)
        )
        subject.powerSource.sendChange()

        #expect(subject.awakeService.hasLease(for: .awayMode))
        #expect(subject.backend.activeIDs.count == 1)
        #expect(subject.coordinator.powerWarning == nil)
    }

    @Test("Failed lease cleanup retains exclusive admission and blocks reentry")
    func failedLeaseCleanupRetainsAdmission() async {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.backend.failingReleaseIDs = [1]

        subject.coordinator.requestAuthentication()
        await settle()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.backend.activeIDs == [1])
        #expect(subject.mutationAdmission.activeExclusiveOwner == .awayMode)
        #expect(throws: MutationAdmissionError.exclusivePermitActive(owner: .awayMode)) {
            try subject.mutationAdmission.acquire(owner: .scene, mode: .shared)
        }

        let prepareCount = subject.windows.prepareCallCount
        subject.coordinator.startCountdown()
        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.lastErrorMessage == AwayModeActivationError.cleanupPending.message)
        #expect(subject.windows.prepareCallCount == prepareCount)
        #expect(subject.mutationAdmission.activeExclusiveOwner == .awayMode)

        subject.backend.failingReleaseIDs = []
        subject.coordinator.startCountdown()
        #expect(subject.coordinator.state == .countdown(remainingSeconds: 5))
        #expect(subject.mutationAdmission.activeExclusiveOwner == nil)
        #expect(subject.backend.activeIDs.isEmpty)
        subject.coordinator.cancelCountdown()
    }

    @Test("A degraded curtain returns to the same warning after failed authentication")
    func degradedStateRestoration() async {
        let subject = AwayCoordinatorHarness()
        subject.authenticator.plans = [.init(succeeds: false, yieldCount: 0)]
        subject.enterGuarded()
        subject.windows.sendCoverageFailure()
        let degraded = AwayModeState.degraded(
            message: "Display coverage could not be restored. Existing curtains remain visible."
        )
        #expect(subject.coordinator.state == degraded)

        subject.coordinator.requestAuthentication()
        await settle()

        #expect(subject.coordinator.state == degraded)
        #expect(subject.windows.isPresented)
        #expect(Array(subject.input.policies.suffix(2)) == [.systemAuthentication, .fullFiltering])
    }

    @Test("Restored display coverage clears the degraded state")
    func restoredDisplayCoverage() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.windows.sendCoverageFailure()
        #expect(subject.coordinator.state != .guarded)

        subject.windows.sendCoverageRestored()

        #expect(subject.coordinator.state == .guarded)
        #expect(subject.coordinator.lastErrorMessage == nil)
    }

    @Test("Restored input filtering clears only its matching degraded state")
    func restoredInputFiltering() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.input.sendFailure()
        #expect(subject.coordinator.state == .degraded(
            message: "Input filtering stopped. Use Mac authentication or Force Quit."
        ))

        subject.input.sendRestored()

        #expect(subject.coordinator.state == .guarded)
        #expect(subject.coordinator.lastErrorMessage == nil)
    }

    @Test("Overlapping failures clear independently")
    func overlappingFailuresClearIndependently() {
        let subject = AwayCoordinatorHarness()
        subject.enterGuarded()
        subject.windows.sendCoverageFailure()
        subject.input.sendFailure()
        #expect(subject.coordinator.state == .degraded(
            message: "Display coverage could not be restored and input filtering stopped. Existing curtains remain visible. Use Mac authentication or Force Quit."
        ))

        subject.input.sendRestored()
        #expect(subject.coordinator.state == .degraded(
            message: "Display coverage could not be restored. Existing curtains remain visible."
        ))

        subject.windows.sendCoverageRestored()
        #expect(subject.coordinator.state == .guarded)
    }

    @Test("Shutdown tears down every owned resource")
    func shutdown() {
        let subject = AwayCoordinatorHarness(keepsDisplayAwake: true)
        subject.enterGuarded()

        subject.coordinator.shutdown()

        #expect(subject.coordinator.state == .inactive)
        #expect(subject.coordinator.sessionStartedAt == nil)
        #expect(!subject.windows.isPresented)
        #expect(!subject.input.isActive)
        #expect(!subject.presentation.isActive)
        #expect(subject.backend.activeIDs.isEmpty)
        #expect(!subject.awakeService.hasLease(for: .awayMode))
        #expect(subject.powerSource.stopCallCount == 1)
        #expect(Array(subject.log.entries.suffix(5)) == [
            "windows.dismiss",
            "presentation.restore",
            "input.stop",
            "power.release.1",
            "power.release.2",
        ])

        subject.coordinator.startCountdown()
        subject.coordinator.shutdown()
        #expect(subject.coordinator.state == .inactive)
        #expect(subject.powerSource.stopCallCount == 1)
    }

    private func settle(iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}

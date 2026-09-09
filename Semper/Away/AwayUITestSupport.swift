#if DEBUG
import AppKit
import Foundation
import IOKit.pwr_mgt
import os
import SwiftUI

struct AwayUITestLaunchOptions: Equatable {
    enum SystemAuthenticationResult: String {
        case success
        case cancelled
        case denied
    }

    static let enabledArgument = "--away-ui-testing"
    static let authenticationPrefix = "--away-ui-auth="
    static let pinPrefix = "--away-ui-pin="
    static let systemAuthenticationPrefix = "--away-ui-system-auth="
    static let autoCountdownArgument = "--away-ui-auto-countdown"

    let authenticationMethod: AwayAuthenticationMethod
    let pin: String
    let systemAuthenticationResult: SystemAuthenticationResult
    let startsCountdownAutomatically: Bool

    var disablesAudioStartup: Bool { true }

    static func parse(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard arguments.contains(enabledArgument) else { return nil }

        let authenticationMethod = value(
            after: authenticationPrefix,
            in: arguments
        ).flatMap(AwayAuthenticationMethod.init(rawValue:)) ?? .pin
        let requestedPIN = value(after: pinPrefix, in: arguments) ?? "0427"
        let pin = AwayPINCodec.isValidPIN(requestedPIN) ? requestedPIN : "0427"
        let authenticationResult = value(
            after: systemAuthenticationPrefix,
            in: arguments
        ).flatMap(SystemAuthenticationResult.init(rawValue:)) ?? .success

        return Self(
            authenticationMethod: authenticationMethod,
            pin: pin,
            systemAuthenticationResult: authenticationResult,
            startsCountdownAutomatically: arguments.contains(autoCountdownArgument)
        )
    }

    private static func value(after prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count))
        }
    }
}

@MainActor
final class AwayUITestSupport {
    private static let logger = Logger(
        subsystem: "systems.semper.Semper",
        category: "AwayUITests"
    )

    let options: AwayUITestLaunchOptions
    let settingsDirectory: URL
    let awakeService: AwakeService

    private let authenticator: AwayUITestSystemAuthenticator
    private let inputGuard: AwayUITestInputGuard
    private let pinStore: AwayUITestPINStore
    private let presentation: AwayUITestPresentationController
    private let powerPolicy: AwayPowerPolicy
    private let photoStore: AwayPhotoStore
    private var hostWindow: NSWindow?

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AwayUITestSupport? {
        guard let options = AwayUITestLaunchOptions.parse(arguments: arguments) else {
            return nil
        }
        return AwayUITestSupport(options: options, temporaryDirectory: temporaryDirectory)
    }

    init(options: AwayUITestLaunchOptions, temporaryDirectory: URL) {
        self.options = options
        settingsDirectory = temporaryDirectory.appendingPathComponent(
            "Semper-Away-UITests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )

        let assertionBackend = AwayUITestPowerAssertionBackend()
        awakeService = AwakeService(backend: assertionBackend)
        authenticator = AwayUITestSystemAuthenticator(
            result: options.systemAuthenticationResult
        )
        inputGuard = AwayUITestInputGuard()
        pinStore = AwayUITestPINStore(pin: options.pin)
        presentation = AwayUITestPresentationController()
        let readingSource = AwayUITestPowerReadingSource()
        powerPolicy = AwayPowerPolicy(source: readingSource)
        photoStore = AwayPhotoStore(
            directory: settingsDirectory.appendingPathComponent("Away", isDirectory: true)
        )
    }

    func prepare(_ settings: SettingsManager) {
        var appSettings = settings.appSettings
        appSettings.awayModePreferences.authenticationMethod = options.authenticationMethod
        appSettings.awayModePreferences.disclosureCompleted = true
        appSettings.awayModePreferences.motionLevel = .off
        appSettings.awayModePreferences.keepsDisplayAwake = false
        settings.appSettings = appSettings
    }

    func makeCoordinator(
        settings: SettingsManager,
        mutationAdmission: MutationAdmissionGate
    ) -> AwayModeCoordinator {
        AwayModeCoordinator(
            settings: settings,
            awakeService: awakeService,
            mutationAdmission: mutationAdmission,
            inputGuard: inputGuard,
            authenticator: authenticator,
            pinStore: pinStore,
            photoStore: photoStore,
            presentation: presentation,
            powerPolicy: powerPolicy
        )
    }

    func showHostWindow(
        coordinator: AwayModeCoordinator,
        onOpenSettings: @escaping @MainActor () -> Void = {}
    ) {
        let rootView = AwayModuleView(
            coordinator: coordinator,
            onOpenSettings: onOpenSettings
        )
        .frame(width: 420)
        .frame(minHeight: 360)
        .padding(24)
        .accessibilityIdentifier("away-ui-test-host")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Semper Away Mode UI Tests"
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hostWindow = window

        if options.startsCountdownAutomatically {
            coordinator.startCountdown()
        }
    }

    func cleanUp() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        awakeService.shutdown()
        powerPolicy.shutdown()
        do {
            try FileManager.default.removeItem(at: settingsDirectory)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            Self.logger.error(
                "Could not delete the temporary UI test directory: \(error.localizedDescription)"
            )
        }
    }
}

@MainActor
private final class AwayUITestSystemAuthenticator: AwaySystemAuthenticating {
    private let result: AwayUITestLaunchOptions.SystemAuthenticationResult

    init(result: AwayUITestLaunchOptions.SystemAuthenticationResult) {
        self.result = result
    }

    func isAvailable() -> Bool {
        true
    }

    func authenticate(reason: String) async throws {
        await Task.yield()
        switch result {
        case .success:
            return
        case .cancelled:
            throw AwayAuthenticationError.cancelled
        case .denied:
            throw AwayAuthenticationError.denied
        }
    }
}

private final class AwayUITestPINStore: AwayPINStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pin: String?

    init(pin: String?) {
        self.pin = pin
    }

    func hasPIN() throws -> Bool {
        lock.withLock { pin != nil }
    }

    func preparePIN(_ pin: String) throws -> AwayPreparedPIN {
        guard AwayPINCodec.isValidPIN(pin) else {
            throw AwayPINStoreError.invalidPINFormat
        }
        return AwayPreparedPIN(data: Data(pin.utf8))
    }

    func commitPIN(_ preparedPIN: AwayPreparedPIN) throws {
        let pin = String(decoding: preparedPIN.data, as: UTF8.self)
        guard AwayPINCodec.isValidPIN(pin) else {
            throw AwayPINStoreError.invalidStoredRecord
        }
        lock.withLock {
            self.pin = pin
        }
    }

    func verifyPIN(_ pin: String) throws -> Bool {
        guard AwayPINCodec.isValidPIN(pin) else {
            throw AwayPINStoreError.invalidPINFormat
        }
        return lock.withLock {
            self.pin == pin
        }
    }

    func removePIN() throws {
        lock.withLock {
            pin = nil
        }
    }
}

@MainActor
private final class AwayUITestPowerAssertionBackend: PowerAssertionCreating {
    private var nextIdentifier: PowerAssertionID = 1
    private var activeIdentifiers: Set<PowerAssertionID> = []

    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID {
        let identifier = nextIdentifier
        nextIdentifier += 1
        activeIdentifiers.insert(identifier)
        return identifier
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        guard activeIdentifiers.remove(id) != nil else {
            throw .releaseFailed(kIOReturnNotFound)
        }
    }
}

@MainActor
private final class AwayUITestInputGuard: AwayInputGuarding {
    private(set) var isActive = false
    private(set) var policy: AwayInputPolicy = .fullFiltering
    var isFilteringOperational: Bool { isActive }
    var hasEventAccess: Bool { true }
    var onActivity: (() -> Void)?
    var onAuthenticationRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?
    var onFailure: ((AwayInputGuardFailure) -> Void)?
    var onRestored: (() -> Void)?

    func preflight() -> Bool {
        true
    }

    func requestEventAccess() {}

    func start(policy: AwayInputPolicy) -> Bool {
        self.policy = policy
        isActive = true
        return true
    }

    func setPolicy(_ policy: AwayInputPolicy) {
        self.policy = policy
    }

    func setAuthenticationShortcut(_ shortcut: ShortcutCodable?) {}

    func handleTapDisabled() {
        isActive = true
        onRestored?()
    }

    func stop() {
        isActive = false
        policy = .fullFiltering
    }
}

@MainActor
private final class AwayUITestPresentationController: AwayApplicationPresenting {
    private(set) var isActive = false

    func begin() throws {
        guard !isActive else {
            throw AwayApplicationPresentationError.alreadyActive
        }
        isActive = true
    }

    func restore() {
        isActive = false
    }
}

@MainActor
private final class AwayUITestPowerReadingSource: AwayPowerReadingSource {
    func currentReading() -> AwayPowerReading {
        AwayPowerReading(
            isLowPowerModeEnabled: false,
            thermalPressure: .nominal,
            powerSupply: .ac(percentage: 100, isCharging: false)
        )
    }

    func startMonitoring(_ handler: @escaping @MainActor @Sendable () -> Void) {}

    func stopMonitoring() {}
}
#endif

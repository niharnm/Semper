import Foundation
import IOKit.pwr_mgt
import os

typealias PowerAssertionID = IOPMAssertionID

enum PowerAssertionKind: CaseIterable, Sendable {
    case preventIdleSystemSleep
    case preventIdleDisplaySleep

    var ioKitType: String {
        switch self {
        case .preventIdleSystemSleep:
            kIOPMAssertPreventUserIdleSystemSleep
        case .preventIdleDisplaySleep:
            kIOPMAssertPreventUserIdleDisplaySleep
        }
    }
}

enum PowerAssertionError: Error, Equatable, Sendable {
    case creationFailed(IOReturn)
    case nullIdentifier
    case releaseFailed(IOReturn)
}

@MainActor
protocol PowerAssertionCreating: AnyObject {
    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError)
}

@MainActor
final class IOPMPowerAssertionBackend: PowerAssertionCreating {
    private static let assertionName = "Semper Awake"

    private let logger = Logger(subsystem: "systems.semper.Semper", category: "Awake")

    func createAssertion(
        kind: PowerAssertionKind,
        reason: String,
        timeout: TimeInterval?
    ) throws(PowerAssertionError) -> PowerAssertionID {
        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let timeoutAction: CFString? = timeout.map { _ in
            kIOPMAssertionTimeoutActionTurnOff as CFString
        }
        let status = IOPMAssertionCreateWithDescription(
            kind.ioKitType as CFString,
            Self.assertionName as CFString,
            reason as CFString,
            nil,
            nil,
            timeout ?? 0,
            timeoutAction,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            logger.error(
                "Power assertion creation failed: type \(kind.ioKitType, privacy: .public), status \(status)"
            )
            throw PowerAssertionError.creationFailed(status)
        }
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            logger.error("Power assertion creation returned a null identifier")
            throw PowerAssertionError.nullIdentifier
        }
        return assertionID
    }

    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        let status = IOPMAssertionRelease(id)
        guard status == kIOReturnSuccess else {
            logger.error("Power assertion release failed: id \(id), status \(status)")
            throw PowerAssertionError.releaseFailed(status)
        }
    }
}

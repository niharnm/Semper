import Foundation
import LocalAuthentication

enum AwayAuthenticationError: Error, Equatable, Sendable {
    case invalidReason
    case unavailable(code: Int)
    case cancelled
    case denied
    case systemFailure(code: Int)
}

@MainActor
protocol AwaySystemAuthenticating: AnyObject {
    func isAvailable() -> Bool
    func authenticate(reason: String) async throws
    func cancelAuthentication()
}

@MainActor
protocol AwayAuthenticationContext: AnyObject {
    func checkAvailability() throws
    func authenticate(reason: String) async throws -> Bool
    func invalidate()
}

@MainActor
final class LocalAwayAuthenticationContext: AwayAuthenticationContext {
    private let context: LAContext

    init(context: LAContext = LAContext()) {
        self.context = context
    }

    func checkAvailability() throws {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: LAError.errorDomain, code: LAError.notInteractive.rawValue)
        }
    }

    func authenticate(reason: String) async throws -> Bool {
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    func invalidate() {
        context.invalidate()
    }
}

@MainActor
final class LocalAwaySystemAuthenticator: AwaySystemAuthenticating {
    typealias ContextFactory = @MainActor () -> any AwayAuthenticationContext

    private let contextFactory: ContextFactory
    private var activeContext: (any AwayAuthenticationContext)?
    private var activeAttemptID: UUID?

    init(contextFactory: @escaping ContextFactory = { LocalAwayAuthenticationContext() }) {
        self.contextFactory = contextFactory
    }

    func isAvailable() -> Bool {
        let context = contextFactory()
        do {
            try context.checkAvailability()
            return true
        } catch {
            return false
        }
    }

    func authenticate(reason: String) async throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AwayAuthenticationError.invalidReason
        }
        guard !Task.isCancelled else {
            throw AwayAuthenticationError.cancelled
        }

        let context = contextFactory()
        do {
            try context.checkAvailability()
        } catch {
            throw map(error, unavailable: true)
        }

        let attemptID = UUID()
        activeContext = context
        activeAttemptID = attemptID
        defer {
            if activeContext === context, activeAttemptID == attemptID {
                activeContext = nil
                activeAttemptID = nil
            }
        }

        do {
            let succeeded = try await withTaskCancellationHandler {
                try await context.authenticate(reason: reason)
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelAuthentication(attemptID: attemptID)
                }
            }
            guard !Task.isCancelled else {
                cancelAuthentication(attemptID: attemptID)
                throw AwayAuthenticationError.cancelled
            }
            guard succeeded else {
                throw AwayAuthenticationError.denied
            }
        } catch let error as AwayAuthenticationError {
            throw error
        } catch {
            throw map(error, unavailable: false)
        }
    }

    func cancelAuthentication() {
        activeContext?.invalidate()
        activeContext = nil
        activeAttemptID = nil
    }

    private func cancelAuthentication(attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        cancelAuthentication()
    }

    private func map(_ error: Error, unavailable: Bool) -> AwayAuthenticationError {
        let nsError = error as NSError
        if nsError.domain == LAError.errorDomain {
            switch LAError.Code(rawValue: nsError.code) {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .authenticationFailed:
                return .denied
            default:
                break
            }
        }
        return unavailable
            ? .unavailable(code: nsError.code)
            : .systemFailure(code: nsError.code)
    }
}

struct AwayPINCooldown: Equatable, Sendable {
    static let failureThreshold = 5
    static let maximumDelay: TimeInterval = 900

    private(set) var failureCount = 0
    private(set) var cooldownUntil: Date?

    func remainingTime(at date: Date) -> TimeInterval {
        guard let cooldownUntil else { return 0 }
        return max(0, cooldownUntil.timeIntervalSince(date))
    }

    func isCoolingDown(at date: Date) -> Bool {
        remainingTime(at: date) > 0
    }

    @discardableResult
    mutating func recordFailure(at date: Date) -> TimeInterval? {
        failureCount += 1
        guard failureCount >= Self.failureThreshold else {
            cooldownUntil = nil
            return nil
        }

        let exponent = min(failureCount - Self.failureThreshold, 30)
        let delay = min(30 * pow(2, Double(exponent)), Self.maximumDelay)
        cooldownUntil = date.addingTimeInterval(delay)
        return delay
    }

    mutating func recordSuccess() {
        failureCount = 0
        cooldownUntil = nil
    }
}

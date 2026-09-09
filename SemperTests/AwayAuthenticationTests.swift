import Foundation
import LocalAuthentication
import Testing
@testable import Semper

@MainActor
private final class AwayAuthenticationContextStub: AwayAuthenticationContext {
    var availabilityError: Error?
    var authenticationError: Error?
    var result = true
    var waitsForInvalidation = false
    private(set) var reasons: [String] = []
    private(set) var authenticationStarted = false
    private(set) var invalidationCount = 0
    private var continuation: CheckedContinuation<Bool, Error>?

    func checkAvailability() throws {
        if let availabilityError {
            throw availabilityError
        }
    }

    func authenticate(reason: String) async throws -> Bool {
        reasons.append(reason)
        authenticationStarted = true
        if let authenticationError {
            throw authenticationError
        }
        if waitsForInvalidation {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }
        return result
    }

    func invalidate() {
        invalidationCount += 1
        continuation?.resume(throwing: NSError(
            domain: LAError.errorDomain,
            code: LAError.appCancel.rawValue
        ))
        continuation = nil
    }

    func finishAuthentication(with result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
@Suite("Away system authentication")
struct AwayAuthenticationTests {
    @Test("Availability uses a newly created context")
    func availability() {
        var creationCount = 0
        let authenticator = LocalAwaySystemAuthenticator {
            creationCount += 1
            return AwayAuthenticationContextStub()
        }

        #expect(authenticator.isAvailable())
        #expect(creationCount == 1)
    }

    @Test("Each authentication request uses a fresh context")
    func freshContext() async throws {
        var creationCount = 0
        let authenticator = LocalAwaySystemAuthenticator {
            creationCount += 1
            return AwayAuthenticationContextStub()
        }

        try await authenticator.authenticate(reason: "Return to Semper")
        try await authenticator.authenticate(reason: "Return to Semper")

        #expect(creationCount == 2)
    }

    @Test("Authentication forwards the reason")
    func reasonForwarding() async throws {
        let context = AwayAuthenticationContextStub()
        let authenticator = LocalAwaySystemAuthenticator { context }

        try await authenticator.authenticate(reason: "Return to Semper")

        #expect(context.reasons == ["Return to Semper"])
    }

    @Test("Blank reasons are rejected before context creation")
    func blankReason() async {
        var creationCount = 0
        let authenticator = LocalAwaySystemAuthenticator {
            creationCount += 1
            return AwayAuthenticationContextStub()
        }

        await #expect(throws: AwayAuthenticationError.invalidReason) {
            try await authenticator.authenticate(reason: "  \n")
        }
        #expect(creationCount == 0)
    }

    @Test("A cancelled task does not create an authentication context")
    func cancellationBeforeAuthenticationStarts() async {
        var creationCount = 0
        let authenticator = LocalAwaySystemAuthenticator {
            creationCount += 1
            return AwayAuthenticationContextStub()
        }
        let authentication = Task { @MainActor in
            await Task.yield()
            try await authenticator.authenticate(reason: "Return to Semper")
        }
        authentication.cancel()

        await #expect(throws: AwayAuthenticationError.cancelled) {
            try await authentication.value
        }
        #expect(creationCount == 0)
    }

    @Test("Unavailable system authentication reports its error code")
    func unavailable() async {
        let context = AwayAuthenticationContextStub()
        context.availabilityError = NSError(domain: "test", code: 47)
        let authenticator = LocalAwaySystemAuthenticator { context }

        await #expect(throws: AwayAuthenticationError.unavailable(code: 47)) {
            try await authenticator.authenticate(reason: "Return to Semper")
        }
    }

    @Test("System cancellation errors have a distinct result")
    func cancellationErrors() async {
        let cancellationCodes = [
            LAError.userCancel,
            LAError.appCancel,
            LAError.systemCancel,
        ]

        for code in cancellationCodes {
            let context = AwayAuthenticationContextStub()
            context.authenticationError = NSError(
                domain: LAError.errorDomain,
                code: code.rawValue
            )
            let authenticator = LocalAwaySystemAuthenticator { context }

            await #expect(throws: AwayAuthenticationError.cancelled) {
                try await authenticator.authenticate(reason: "Return to Semper")
            }
        }
    }

    @Test("Authentication failure is denied")
    func authenticationFailure() async {
        let context = AwayAuthenticationContextStub()
        context.authenticationError = NSError(
            domain: LAError.errorDomain,
            code: LAError.authenticationFailed.rawValue
        )
        let authenticator = LocalAwaySystemAuthenticator { context }

        await #expect(throws: AwayAuthenticationError.denied) {
            try await authenticator.authenticate(reason: "Return to Semper")
        }
    }

    @Test("Authentication cancellation invalidates the active context")
    func authenticationCancellationInvalidatesContext() async {
        let context = AwayAuthenticationContextStub()
        context.waitsForInvalidation = true
        let authenticator = LocalAwaySystemAuthenticator { context }
        let authentication = Task { @MainActor in
            try await authenticator.authenticate(reason: "Return to Semper")
        }
        for _ in 0..<1_000 where !context.authenticationStarted {
            await Task.yield()
        }
        #expect(context.authenticationStarted)

        authenticator.cancelAuthentication()

        await #expect(throws: AwayAuthenticationError.cancelled) {
            try await authentication.value
        }
        #expect(context.invalidationCount == 1)
    }

    @Test("Cancelling the caller task invalidates the active context")
    func callerCancellationInvalidatesContext() async {
        let context = AwayAuthenticationContextStub()
        context.waitsForInvalidation = true
        let authenticator = LocalAwaySystemAuthenticator { context }
        let authentication = Task { @MainActor in
            try await authenticator.authenticate(reason: "Return to Semper")
        }
        for _ in 0..<1_000 where !context.authenticationStarted {
            await Task.yield()
        }
        #expect(context.authenticationStarted)

        authentication.cancel()

        await #expect(throws: AwayAuthenticationError.cancelled) {
            try await authentication.value
        }
        #expect(context.invalidationCount == 1)
    }

    @Test("A cancelled task cannot accept a delivered authentication success")
    func cancellationRejectsDeliveredSuccess() async {
        let context = AwayAuthenticationContextStub()
        context.waitsForInvalidation = true
        let authenticator = LocalAwaySystemAuthenticator { context }
        let authentication = Task { @MainActor in
            try await authenticator.authenticate(reason: "Return to Semper")
        }
        for _ in 0..<1_000 where !context.authenticationStarted {
            await Task.yield()
        }
        #expect(context.authenticationStarted)

        context.finishAuthentication(with: true)
        authentication.cancel()

        await #expect(throws: AwayAuthenticationError.cancelled) {
            try await authentication.value
        }
        #expect(context.invalidationCount == 1)
    }

    @Test("Availability checks do not replace an active authentication context")
    func availabilityDoesNotReplaceActiveContext() async {
        let authenticationContext = AwayAuthenticationContextStub()
        authenticationContext.waitsForInvalidation = true
        let availabilityContext = AwayAuthenticationContextStub()
        var contexts: [AwayAuthenticationContextStub] = [
            authenticationContext,
            availabilityContext,
        ]
        let authenticator = LocalAwaySystemAuthenticator {
            contexts.removeFirst()
        }
        let authentication = Task { @MainActor in
            try await authenticator.authenticate(reason: "Return to Semper")
        }
        for _ in 0..<1_000 where !authenticationContext.authenticationStarted {
            await Task.yield()
        }
        #expect(authenticationContext.authenticationStarted)

        #expect(authenticator.isAvailable())
        authenticator.cancelAuthentication()

        await #expect(throws: AwayAuthenticationError.cancelled) {
            try await authentication.value
        }
        #expect(authenticationContext.invalidationCount == 1)
        #expect(availabilityContext.invalidationCount == 0)
    }

    @Test("Availability LA errors retain their code")
    func availabilityLAErrors() async {
        let availabilityCodes = [
            LAError.passcodeNotSet,
            LAError.biometryNotAvailable,
            LAError.biometryNotEnrolled,
            LAError.biometryLockout,
            LAError.notInteractive,
        ]

        for code in availabilityCodes {
            let context = AwayAuthenticationContextStub()
            context.availabilityError = NSError(
                domain: LAError.errorDomain,
                code: code.rawValue
            )
            let authenticator = LocalAwaySystemAuthenticator { context }

            await #expect(throws: AwayAuthenticationError.unavailable(code: code.rawValue)) {
                try await authenticator.authenticate(reason: "Return to Semper")
            }
            #expect(context.reasons.isEmpty)
        }
    }

    @Test("A false policy result is denied")
    func denied() async {
        let context = AwayAuthenticationContextStub()
        context.result = false
        let authenticator = LocalAwaySystemAuthenticator { context }

        await #expect(throws: AwayAuthenticationError.denied) {
            try await authenticator.authenticate(reason: "Return to Semper")
        }
    }

    @Test("Unexpected policy errors retain their code")
    func systemFailure() async {
        let context = AwayAuthenticationContextStub()
        context.authenticationError = NSError(domain: "test", code: 91)
        let authenticator = LocalAwaySystemAuthenticator { context }

        await #expect(throws: AwayAuthenticationError.systemFailure(code: 91)) {
            try await authenticator.authenticate(reason: "Return to Semper")
        }
    }

    @Test("PIN cooldown starts at five failures and reaches its cap")
    func cooldownSchedule() {
        var cooldown = AwayPINCooldown()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for _ in 0..<4 {
            #expect(cooldown.recordFailure(at: now) == nil)
        }
        #expect(cooldown.recordFailure(at: now) == 30)
        #expect(cooldown.recordFailure(at: now) == 60)
        #expect(cooldown.recordFailure(at: now) == 120)
        #expect(cooldown.recordFailure(at: now) == 240)
        #expect(cooldown.recordFailure(at: now) == 480)
        #expect(cooldown.recordFailure(at: now) == 900)
        #expect(cooldown.recordFailure(at: now) == 900)
    }

    @Test("Cooldown expiry keeps failure history until a success")
    func cooldownExpiryAndReset() {
        var cooldown = AwayPINCooldown()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<5 {
            cooldown.recordFailure(at: now)
        }

        #expect(cooldown.isCoolingDown(at: now.addingTimeInterval(29)))
        #expect(cooldown.remainingTime(at: now.addingTimeInterval(29)) == 1)
        #expect(!cooldown.isCoolingDown(at: now.addingTimeInterval(30)))

        cooldown.recordSuccess()
        #expect(cooldown.failureCount == 0)
        #expect(cooldown.cooldownUntil == nil)
    }
}

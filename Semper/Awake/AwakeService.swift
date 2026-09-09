import AppKit
import Foundation

enum AwakeDuration: String, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case untilTurnedOff

    var id: String { rawValue }

    var timeInterval: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .untilTurnedOff: nil
        }
    }

    var label: String {
        switch self {
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilTurnedOff: "Until turned off"
        }
    }

    var accessibilityPhrase: String {
        switch self {
        case .thirtyMinutes: "for 30 minutes"
        case .oneHour: "for 1 hour"
        case .twoHours: "for 2 hours"
        case .untilTurnedOff: "until turned off"
        }
    }
}

struct AwakeSession: Equatable, Sendable {
    let duration: AwakeDuration
    let keepsDisplayAwake: Bool
    let startedAt: Date
    let endsAt: Date?
}

enum AwakeServiceFailure: Error, Equatable, Sendable {
    case couldNotStart
    case couldNotRelease
}

@MainActor
protocol AwakeExpiryScheduling: AnyObject {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void)
    func cancelScheduledExpiry()
}

@MainActor
final class AwakeExpiryTimer: AwakeExpiryScheduling {
    private var timer: Timer?

    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {
        cancelScheduledExpiry()
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            Task { @MainActor in handler() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancelScheduledExpiry() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
@Observable
final class AwakeService {
    private struct OwnedAssertions {
        let system: PowerAssertionID
        let display: PowerAssertionID?
    }

    private static let systemReason = "User-requested awake session"
    private static let displayReason = "User requested that the display stay awake"

    @ObservationIgnored private let backend: any PowerAssertionCreating
    @ObservationIgnored private let scheduler: any AwakeExpiryScheduling
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let workspaceNotificationCenter: NotificationCenter

    private(set) var session: AwakeSession?
    private(set) var keepDisplayAwake = false
    private(set) var failure: AwakeServiceFailure?

    @ObservationIgnored private var ownedAssertions: OwnedAssertions?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var didShutDown = false

    init(
        backend: any PowerAssertionCreating,
        scheduler: any AwakeExpiryScheduling = AwakeExpiryTimer(),
        now: @escaping () -> Date = Date.init,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.backend = backend
        self.scheduler = scheduler
        self.now = now
        self.workspaceNotificationCenter = workspaceNotificationCenter
        subscribeToWake()
    }

    var isActive: Bool {
        session != nil
    }

    var lastActionFailed: Bool {
        failure != nil
    }

    func start(_ duration: AwakeDuration) {
        guard !didShutDown, failure != .couldNotRelease else { return }
        let acquired: OwnedAssertions
        switch acquireAssertions(
            keepDisplayAwake: keepDisplayAwake,
            timeout: duration.timeInterval
        ) {
        case .success(let assertions):
            acquired = assertions
        case .failure(let failure):
            self.failure = failure
            return
        }

        guard replaceOwnedAssertions(with: acquired) else { return }

        let startedAt = now()
        session = AwakeSession(
            duration: duration,
            keepsDisplayAwake: keepDisplayAwake,
            startedAt: startedAt,
            endsAt: duration.timeInterval.map(startedAt.addingTimeInterval)
        )
        failure = nil
        rescheduleExpiry()
    }

    func setKeepDisplayAwake(_ keep: Bool) {
        guard !didShutDown,
              failure != .couldNotRelease,
              keep != keepDisplayAwake else { return }
        guard let current = session else {
            keepDisplayAwake = keep
            return
        }

        let currentDate = now()
        if let endsAt = current.endsAt, currentDate >= endsAt {
            stop()
            keepDisplayAwake = keep
            return
        }

        let acquired: OwnedAssertions
        switch acquireAssertions(
            keepDisplayAwake: keep,
            timeout: current.endsAt.map { $0.timeIntervalSince(currentDate) }
        ) {
        case .success(let assertions):
            acquired = assertions
        case .failure(let failure):
            self.failure = failure
            return
        }

        guard replaceOwnedAssertions(with: acquired) else { return }

        keepDisplayAwake = keep
        session = AwakeSession(
            duration: current.duration,
            keepsDisplayAwake: keep,
            startedAt: current.startedAt,
            endsAt: current.endsAt
        )
        failure = nil
    }

    func stop() {
        scheduler.cancelScheduledExpiry()
        guard session != nil || ownedAssertions != nil else { return }
        session = nil
        // Releasing this session cannot resolve an earlier assertion cleanup failure.
        if failure != .couldNotRelease {
            failure = nil
        }
        if let assertions = takeOwnedAssertions(), !releaseAssertions(assertions) {
            failure = .couldNotRelease
        }
    }

    func reconcile() {
        guard let session, let endsAt = session.endsAt else { return }
        if now() >= endsAt {
            stop()
        } else {
            scheduler.scheduleExpiry(at: endsAt) { [weak self] in
                self?.reconcile()
            }
        }
    }

    func shutdown() {
        guard !didShutDown else { return }
        didShutDown = true
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        scheduler.cancelScheduledExpiry()
        session = nil
        if let assertions = takeOwnedAssertions(), !releaseAssertions(assertions) {
            failure = .couldNotRelease
        }
    }

    private func subscribeToWake() {
        let handler: @MainActor () -> Void = { [weak self] in
            self?.reconcile()
        }
        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func rescheduleExpiry() {
        scheduler.cancelScheduledExpiry()
        guard let endsAt = session?.endsAt else { return }
        scheduler.scheduleExpiry(at: endsAt) { [weak self] in
            self?.reconcile()
        }
    }

    private func acquireAssertions(
        keepDisplayAwake: Bool,
        timeout: TimeInterval?
    ) -> Result<OwnedAssertions, AwakeServiceFailure> {
        let system: PowerAssertionID
        do {
            system = try backend.createAssertion(
                kind: .preventIdleSystemSleep,
                reason: Self.systemReason,
                timeout: timeout
            )
        } catch {
            return .failure(.couldNotStart)
        }

        guard keepDisplayAwake else {
            return .success(OwnedAssertions(system: system, display: nil))
        }

        do {
            let display = try backend.createAssertion(
                kind: .preventIdleDisplaySleep,
                reason: Self.displayReason,
                timeout: timeout
            )
            return .success(OwnedAssertions(system: system, display: display))
        } catch {
            do {
                try backend.releaseAssertion(system)
                return .failure(.couldNotStart)
            } catch {
                return .failure(.couldNotRelease)
            }
        }
    }

    private func replaceOwnedAssertions(with replacement: OwnedAssertions) -> Bool {
        guard let previous = takeOwnedAssertions() else {
            ownedAssertions = replacement
            return true
        }
        guard releaseAssertions(previous) else {
            _ = releaseAssertions(replacement)
            scheduler.cancelScheduledExpiry()
            session = nil
            failure = .couldNotRelease
            return false
        }
        ownedAssertions = replacement
        return true
    }

    private func takeOwnedAssertions() -> OwnedAssertions? {
        let assertions = ownedAssertions
        ownedAssertions = nil
        return assertions
    }

    private func releaseAssertions(_ assertions: OwnedAssertions) -> Bool {
        var succeeded = true
        do {
            try backend.releaseAssertion(assertions.system)
        } catch {
            succeeded = false
        }
        if let display = assertions.display {
            do {
                try backend.releaseAssertion(display)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}

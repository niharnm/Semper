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

enum AwakeLeaseOwner: Hashable, Sendable {
    case awayMode
    case scene
    case presentation

    fileprivate var systemReason: String {
        switch self {
        case .awayMode: "Semper Away Mode requested idle sleep prevention"
        case .scene: "Semper Scene requested idle sleep prevention"
        case .presentation: "Semper Presentation requested idle sleep prevention"
        }
    }

    fileprivate var displayReason: String {
        switch self {
        case .awayMode: "Semper Away Mode requested idle display sleep prevention"
        case .scene: "Semper Scene requested idle display sleep prevention"
        case .presentation: "Semper Presentation requested idle display sleep prevention"
        }
    }
}

struct AwakeLeaseToken: Hashable, Sendable {
    fileprivate let owner: AwakeLeaseOwner
    fileprivate let generation: UUID
}

struct AwakeLeaseState: Equatable, Sendable {
    let owner: AwakeLeaseOwner
    let keepsDisplayAwake: Bool
    let deadline: Date?

    init(owner: AwakeLeaseOwner, keepsDisplayAwake: Bool, deadline: Date? = nil) {
        self.owner = owner
        self.keepsDisplayAwake = keepsDisplayAwake
        self.deadline = deadline
    }
}

enum AwakeLeaseError: Error, Equatable, Sendable {
    case serviceUnavailable
    case invalidToken
    case couldNotAcquire
    case couldNotReplace
    case invalidDeadline
    case conflictingLease
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

        var ids: [PowerAssertionID] {
            [system] + [display].compactMap(\.self)
        }
    }

    private struct LeaseRecord {
        let token: AwakeLeaseToken
        let state: AwakeLeaseState
        let assertions: OwnedAssertions
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
    private(set) var leaseStates: [AwakeLeaseOwner: AwakeLeaseState] = [:]

    @ObservationIgnored private var ownedAssertions: OwnedAssertions?
    @ObservationIgnored private var leases: [AwakeLeaseOwner: LeaseRecord] = [:]
    @ObservationIgnored private var pendingSessionReleaseIDs = Set<PowerAssertionID>()
    @ObservationIgnored private var pendingLeaseReleaseIDs = Set<PowerAssertionID>()
    @ObservationIgnored private var pendingLeaseReleaseIDsByToken: [AwakeLeaseToken: Set<PowerAssertionID>] = [:]
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

    var effectiveLeaseCount: Int {
        leaseStates.count
    }

    var hasEffectiveAwakeRequest: Bool {
        session != nil || !leaseStates.isEmpty
    }

    func leaseState(for owner: AwakeLeaseOwner) -> AwakeLeaseState? {
        leaseStates[owner]
    }

    func hasLease(for owner: AwakeLeaseOwner) -> Bool {
        leaseStates[owner] != nil
    }

    func acquireLease(
        owner: AwakeLeaseOwner,
        keepsDisplayAwake: Bool,
        deadline: Date? = nil
    ) throws(AwakeLeaseError) -> AwakeLeaseToken {
        if owner == .presentation, deadline == nil {
            throw .invalidDeadline
        }
        let timeout = deadline.map { $0.timeIntervalSince(now()) }
        if let timeout, !timeout.isFinite || timeout <= 0 {
            throw .invalidDeadline
        }
        reconcile()
        guard !didShutDown, failure != .couldNotRelease else {
            throw .serviceUnavailable
        }

        if let existing = leases[owner] {
            guard existing.state.deadline == deadline,
                  owner != .presentation || existing.state.keepsDisplayAwake == keepsDisplayAwake else {
                throw .conflictingLease
            }
            if existing.state.keepsDisplayAwake != keepsDisplayAwake {
                try updateLease(existing.token, keepsDisplayAwake: keepsDisplayAwake)
            }
            return existing.token
        }

        let acquired: OwnedAssertions
        switch acquireAssertions(
            keepDisplayAwake: keepsDisplayAwake,
            timeout: nil,
            deadline: deadline,
            systemReason: owner.systemReason,
            displayReason: owner.displayReason,
            trackLeaseCleanup: true,
            leaseToken: nil
        ) {
        case .success(let assertions):
            acquired = assertions
        case .failure(let serviceFailure):
            failure = serviceFailure
            throw .couldNotAcquire
        }

        let token = AwakeLeaseToken(owner: owner, generation: UUID())
        let state = AwakeLeaseState(owner: owner, keepsDisplayAwake: keepsDisplayAwake, deadline: deadline)
        leases[owner] = LeaseRecord(token: token, state: state, assertions: acquired)
        leaseStates[owner] = state
        failure = nil
        rescheduleExpiry()
        return token
    }

    func updateLease(
        _ token: AwakeLeaseToken,
        keepsDisplayAwake: Bool
    ) throws(AwakeLeaseError) {
        guard !didShutDown, failure != .couldNotRelease else {
            throw .serviceUnavailable
        }
        guard let existing = leases[token.owner], existing.token == token else {
            throw .invalidToken
        }
        let timeout = existing.state.deadline.map { $0.timeIntervalSince(now()) }
        if let timeout, !timeout.isFinite || timeout <= 0 {
            _ = releaseLease(token)
            throw .invalidToken
        }
        guard existing.state.keepsDisplayAwake != keepsDisplayAwake else { return }
        defer { rescheduleExpiry() }

        let acquired: OwnedAssertions
        switch acquireAssertions(
            keepDisplayAwake: keepsDisplayAwake,
            timeout: nil,
            deadline: existing.state.deadline,
            systemReason: token.owner.systemReason,
            displayReason: token.owner.displayReason,
            trackLeaseCleanup: true,
            leaseToken: token
        ) {
        case .success(let assertions):
            acquired = assertions
        case .failure(let serviceFailure):
            failure = serviceFailure
            throw .couldNotAcquire
        }

        guard releaseLeaseAssertions(existing.assertions, for: token) else {
            _ = releaseLeaseAssertions(acquired, for: token)
            leases[token.owner] = nil
            leaseStates[token.owner] = nil
            failure = .couldNotRelease
            throw .couldNotReplace
        }

        let state = AwakeLeaseState(
            owner: token.owner, keepsDisplayAwake: keepsDisplayAwake, deadline: existing.state.deadline
        )
        leases[token.owner] = LeaseRecord(token: token, state: state, assertions: acquired)
        leaseStates[token.owner] = state
        failure = nil
    }

    @discardableResult
    func releaseLease(_ token: AwakeLeaseToken) -> Bool {
        guard let existing = leases[token.owner], existing.token == token else {
            return pendingLeaseReleaseIDsByToken[token] == nil
        }
        defer { rescheduleExpiry() }

        leases[token.owner] = nil
        leaseStates[token.owner] = nil
        guard releaseLeaseAssertions(existing.assertions, for: token) else {
            failure = .couldNotRelease
            return false
        }
        guard pendingLeaseReleaseIDsByToken[token] == nil else {
            failure = .couldNotRelease
            return false
        }
        if failure != .couldNotRelease {
            failure = nil
        }
        return true
    }

    func start(_ duration: AwakeDuration) {
        guard !didShutDown, failure != .couldNotRelease else { return }
        let acquired: OwnedAssertions
        switch acquireAssertions(
            keepDisplayAwake: keepDisplayAwake,
            timeout: duration.timeInterval,
            systemReason: Self.systemReason,
            displayReason: Self.displayReason,
            trackLeaseCleanup: false,
            leaseToken: nil
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
            timeout: current.endsAt.map { $0.timeIntervalSince(currentDate) },
            systemReason: Self.systemReason,
            displayReason: Self.displayReason,
            trackLeaseCleanup: false,
            leaseToken: nil
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
        defer { rescheduleExpiry() }
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
        guard !didShutDown else { return }
        let currentDate = now()
        if let endsAt = session?.endsAt, currentDate >= endsAt {
            stop()
        }
        for record in Array(leases.values) {
            if let deadline = record.state.deadline, currentDate >= deadline {
                _ = releaseLease(record.token)
            }
        }
        rescheduleExpiry()
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
        let leaseRecords = Array(leases.values)
        leases.removeAll()
        leaseStates.removeAll()
        for record in leaseRecords where !releaseLeaseAssertions(
            record.assertions,
            for: record.token
        ) {
            failure = .couldNotRelease
        }
        retryPendingReleasesAtShutdown()
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
        guard !didShutDown else { return }
        let deadlines = leases.values.compactMap(\.state.deadline) + [session?.endsAt].compactMap(\.self)
        guard let deadline = deadlines.min() else { return }
        scheduler.scheduleExpiry(at: deadline) { [weak self] in
            self?.reconcile()
        }
    }

    private func acquireAssertions(
        keepDisplayAwake: Bool,
        timeout: TimeInterval?,
        deadline: Date? = nil,
        systemReason: String,
        displayReason: String,
        trackLeaseCleanup: Bool,
        leaseToken: AwakeLeaseToken?
    ) -> Result<OwnedAssertions, AwakeServiceFailure> {
        func remainingTimeout() throws(AwakeServiceFailure) -> TimeInterval? {
            guard let deadline else { return timeout }
            let remaining = deadline.timeIntervalSince(now())
            guard remaining.isFinite, remaining > 0 else { throw .couldNotStart }
            return remaining
        }

        let system: PowerAssertionID
        do {
            system = try backend.createAssertion(
                kind: .preventIdleSystemSleep,
                reason: systemReason,
                timeout: remainingTimeout()
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
                reason: displayReason,
                timeout: remainingTimeout()
            )
            return .success(OwnedAssertions(system: system, display: display))
        } catch {
            do {
                try backend.releaseAssertion(system)
                return .failure(.couldNotStart)
            } catch {
                if trackLeaseCleanup {
                    rememberPendingLeaseReleaseIDs(Set([system]), for: leaseToken)
                } else {
                    pendingSessionReleaseIDs.insert(system)
                }
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
            session = nil
            rescheduleExpiry()
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
        let failedIDs = releaseAssertionIDs(assertions.ids)
        pendingSessionReleaseIDs.formUnion(failedIDs)
        return failedIDs.isEmpty
    }

    private func releaseLeaseAssertions(
        _ assertions: OwnedAssertions,
        for token: AwakeLeaseToken
    ) -> Bool {
        let failedIDs = releaseAssertionIDs(assertions.ids)
        rememberPendingLeaseReleaseIDs(failedIDs, for: token)
        return failedIDs.isEmpty
    }

    private func releaseAssertionIDs<S: Sequence>(_ ids: S) -> Set<PowerAssertionID>
    where S.Element == PowerAssertionID {
        var failedIDs = Set<PowerAssertionID>()
        for id in ids {
            do {
                try backend.releaseAssertion(id)
            } catch {
                failedIDs.insert(id)
            }
        }
        return failedIDs
    }

    private func rememberPendingLeaseReleaseIDs(
        _ ids: Set<PowerAssertionID>,
        for token: AwakeLeaseToken?
    ) {
        guard !ids.isEmpty else { return }
        pendingLeaseReleaseIDs.formUnion(ids)
        if let token {
            pendingLeaseReleaseIDsByToken[token, default: []].formUnion(ids)
        }
    }

    private func retryPendingReleasesAtShutdown() {
        guard !pendingSessionReleaseIDs.isEmpty || !pendingLeaseReleaseIDs.isEmpty else {
            return
        }
        pendingSessionReleaseIDs = releaseAssertionIDs(pendingSessionReleaseIDs.sorted())
        let failedLeaseIDs = releaseAssertionIDs(pendingLeaseReleaseIDs.sorted())
        pendingLeaseReleaseIDs = failedLeaseIDs

        for token in Array(pendingLeaseReleaseIDsByToken.keys) {
            let remaining = pendingLeaseReleaseIDsByToken[token, default: []]
                .intersection(failedLeaseIDs)
            pendingLeaseReleaseIDsByToken[token] = remaining.isEmpty ? nil : remaining
        }

        if pendingSessionReleaseIDs.isEmpty, failedLeaseIDs.isEmpty {
            if failure == .couldNotRelease { failure = nil }
        } else {
            failure = .couldNotRelease
        }
    }
}

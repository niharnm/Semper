import AppKit
import Synchronization
import Testing

@testable import Semper

@Suite("Display identification lifecycle")
@MainActor
struct DisplayIdentificationControllerTests {
    typealias Controller = DisplayIdentificationController

    @Test("All current screens get an ordered number and an inset-free bounded frame")
    func identifiesCurrentScreens() throws {
        let fixture = IdentificationFixture()
        let values = try fixture.controller.identifyAll().get()
        #expect(values.map(\.displayID) == [11, 22])
        #expect(values.map(\.number) == [1, 2])
        #expect(values.map(\.name) == ["Left", "Right"])
        for (value, screen) in zip(values, fixture.screens) {
            #expect(screen.visibleFrame.contains(value.frame))
            #expect(value.frame.midX == screen.visibleFrame.midX)
            #expect(value.frame.midY == screen.visibleFrame.midY)
        }
        #expect(fixture.presented == values)
        #expect(fixture.controller.isActive)
        #expect(fixture.center.observerCount == 1)
        fixture.controller.stop()
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
    }

    @Test("Explicit IDs retain their number from the complete current screen snapshot")
    func explicitTarget() throws {
        let fixture = IdentificationFixture()
        let values = try fixture.controller.identify(displayID: 22).get()
        #expect(values.map(\.displayID) == [22])
        #expect(values.map(\.number) == [2])
        #expect(fixture.presented.count == 1)
        fixture.controller.stop()
    }

    @Test("Missing targets clear previous panels and are never guessed")
    func absentAndDisconnectedTargets() throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        fixture.screens.removeLast()
        #expect(fixture.controller.identify(displayID: 22) == .failure(.displayNotFound(22)))
        #expect(fixture.closed == [11, 22])
        #expect(fixture.presented.count == 2)
        #expect(!fixture.controller.isActive)
        #expect(fixture.center.observerCount == 0)
        fixture.screens = []
        #expect(fixture.controller.identifyAll() == .failure(.noScreens))
        #expect(fixture.controller.identify(displayID: 11) == .failure(.displayNotFound(11)))
    }

    @Test("Invalid geometry fails the entire request before presenting any panel")
    func invalidGeometry() throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identify(displayID: 11).get()
        for bounds in [CGRect.zero, CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)] {
            fixture.screens[1] = .init(displayID: 22, name: "Invalid", visibleFrame: bounds)
            #expect(fixture.controller.identifyAll() == .failure(.invalidScreenGeometry(22)))
            #expect(fixture.presented.count == 1)
            #expect(fixture.closed == [11])
            #expect(fixture.center.observerCount == 0)
        }
    }

    @Test("Small screen bounds constrain both panel dimensions")
    func smallScreen() throws {
        let fixture = IdentificationFixture()
        let bounds = CGRect(x: -20, y: 30, width: 100, height: 80)
        fixture.screens = [.init(displayID: 33, name: "Small", visibleFrame: bounds)]
        let value = try #require(fixture.controller.identifyAll().get().first)
        #expect(value.frame == bounds)
        fixture.controller.stop()
    }

    @Test("Timeout uses a fixed three-second duration and releases panels and observer")
    func timeout() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        #expect(fixture.clock.requests == [.seconds(3)])
        fixture.clock.finish(0)
        try await waitUntil { !fixture.controller.isActive }
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
    }

    @Test("Repeated requests close the old panels before showing new ones")
    func repeatAndStaleTimer() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identify(displayID: 11).get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        _ = try fixture.controller.identify(displayID: 22).get()
        try await waitUntil { fixture.clock.requests.count == 2 }
        #expect(fixture.events == ["show 11", "close 11", "show 22"])
        #expect(fixture.center.observerCount == 1)
        // This clock intentionally completes a canceled sleep successfully.
        fixture.clock.finish(0)
        try await waitUntil { fixture.clock.completions == 1 }
        #expect(fixture.controller.isActive)
        #expect(fixture.closed == [11])
        fixture.clock.finish(1)
        try await waitUntil { !fixture.controller.isActive }
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
    }

    @Test("Clear is reusable and its old timer cannot close the next request")
    func clearAndReuse() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identify(displayID: 11).get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        fixture.controller.clear()
        fixture.controller.clear()
        #expect(fixture.closed == [11])
        #expect(fixture.center.observerCount == 0)
        _ = try fixture.controller.identify(displayID: 22).get()
        try await waitUntil { fixture.clock.requests.count == 2 }
        fixture.clock.finish(0)
        try await waitUntil { fixture.clock.completions == 1 }
        #expect(fixture.controller.isActive)
        fixture.controller.stop()
        fixture.clock.finish(1)
    }

    @Test("Screen topology changes close every panel and release owned observation")
    func topologyChange() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await waitUntil { !fixture.controller.isActive }
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
        fixture.clock.finish(0)
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(fixture.closed == [11, 22])
    }

    @Test("A queued topology callback from an older request cannot close a newer request")
    func staleTopologyCallback() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identify(displayID: 11).get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        _ = try fixture.controller.identify(displayID: 22).get()
        try await waitUntil { fixture.clock.requests.count == 2 }
        #expect(fixture.controller.isActive)
        #expect(fixture.closed == [11])
        #expect(fixture.center.observerCount == 1)
        fixture.controller.stop()
        fixture.clock.finishAll()
    }

    @Test("Stop is terminal, idempotent and rejects requests before taking another snapshot")
    func shutdown() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        fixture.controller.stop()
        fixture.controller.stop()
        #expect(fixture.controller.identifyAll() == .failure(.stopped))
        #expect(fixture.controller.identify(displayID: 11) == .failure(.stopped))
        #expect(fixture.snapshotCount == 1)
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
        fixture.clock.finish(0)
        try await waitUntil { fixture.clock.completions == 1 }
        #expect(!fixture.controller.isActive)
    }

    @Test("A clock failure still clears the active request")
    func failedClock() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        fixture.clock.finish(0, error: CancellationError())
        try await waitUntil { !fixture.controller.isActive }
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
    }

    @Test("Releasing the controller cleans up panels without waiting for its clock")
    func deinitialization() async throws {
        let fixture = IdentificationFixture()
        _ = try fixture.controller.identifyAll().get()
        try await waitUntil { fixture.clock.requests.count == 1 }
        weak var released: Controller?
        released = fixture.controllerStorage
        fixture.controllerStorage = nil
        #expect(released == nil)
        #expect(fixture.closed == [11, 22])
        #expect(fixture.center.observerCount == 0)
        fixture.clock.finish(0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition())
    }
}

@MainActor
private final class IdentificationFixture {
    typealias Controller = DisplayIdentificationController
    var screens: [Controller.Screen] = [
        .init(displayID: 11, name: "Left", visibleFrame: CGRect(x: -1200, y: 20, width: 1200, height: 800)),
        .init(displayID: 22, name: "Right", visibleFrame: CGRect(x: 0, y: -400, width: 1600, height: 900)),
    ]
    let center = IdentificationNotificationCenter()
    let clock = IdentificationClock()
    var presented: [Controller.Identification] = []
    var closed: [CGDirectDisplayID] = []
    var events: [String] = []
    var snapshotCount = 0
    var controllerStorage: Controller?
    var controller: Controller { controllerStorage! }

    init() {
        controllerStorage = Controller(
            screenSnapshot: { [weak self] in
                self?.snapshotCount += 1
                return self?.screens ?? []
            },
            present: { [weak self] identification in
                self?.presented.append(identification)
                self?.events.append("show \(identification.displayID)")
                return { [weak self] in
                    self?.closed.append(identification.displayID)
                    self?.events.append("close \(identification.displayID)")
                }
            },
            sleep: { [clock] duration in try await clock.sleep(duration) },
            notificationCenter: center
        )
    }

    isolated deinit {
        controllerStorage?.stop()
        clock.finishAll()
    }
}

@MainActor
private final class IdentificationClock {
    private(set) var requests: [Duration] = []
    private(set) var completions = 0
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = requests.count
        requests.append(duration)
        defer { completions += 1 }
        try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }

    func finish(_ id: Int, error: (any Error)? = nil) {
        let continuation = continuations.removeValue(forKey: id)
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func finishAll() {
        for id in Array(continuations.keys) { finish(id, error: CancellationError()) }
    }
}

nonisolated private final class IdentificationNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let count = Mutex(0)
    var observerCount: Int { count.withLock { $0 } }

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        count.withLock { $0 += 1 }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        count.withLock { $0 -= 1 }
        super.removeObserver(observer)
    }
}

import AppKit
import Testing

@testable import Semper

@MainActor
@Suite("Sound detail window visibility", .serialized)
struct SoundDetailVisibilityTests {
    @Test("Meters stay stopped until their hosting window is visible")
    func startsHidden() async {
        let fixture = Fixture()
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        #expect(fixture.updates == [false])

        fixture.window.fakeVisible = true
        fixture.post(NSWindow.didChangeOcclusionStateNotification)
        await fixture.waitForUpdates(2)
        #expect(fixture.updates == [false, true])
    }

    @Test("Other windows cannot change meter visibility")
    func ignoresOtherWindows() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        let otherWindow = VisibilityTestWindow()
        fixture.window.fakeVisible = false
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: otherWindow)
        fixture.center.post(name: NSWindow.willCloseNotification, object: otherWindow)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.updates == [true])

        fixture.post(NSWindow.didChangeOcclusionStateNotification)
        await fixture.waitForUpdates(2)
        #expect(fixture.updates == [true, false])
    }

    @Test("Minimizing, covering, hiding, and closing the host stop meters")
    func followsHostVisibility() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)

        fixture.window.fakeMiniaturized = true
        fixture.post(NSWindow.didMiniaturizeNotification)
        await fixture.waitForUpdates(2)
        fixture.window.fakeMiniaturized = false
        fixture.post(NSWindow.didDeminiaturizeNotification)
        await fixture.waitForUpdates(3)

        fixture.window.fakeOccluded = true
        fixture.post(NSWindow.didChangeOcclusionStateNotification)
        await fixture.waitForUpdates(4)
        fixture.window.fakeOccluded = false
        fixture.post(NSWindow.didChangeOcclusionStateNotification)
        await fixture.waitForUpdates(5)

        fixture.applicationHidden = true
        fixture.center.post(name: NSApplication.didHideNotification, object: nil)
        await fixture.waitForUpdates(6)
        fixture.applicationHidden = false
        fixture.center.post(name: NSApplication.didUnhideNotification, object: nil)
        await fixture.waitForUpdates(7)

        fixture.post(NSWindow.willCloseNotification)
        fixture.post(NSWindow.didResignKeyNotification)
        await fixture.waitForUpdates(8)
        #expect(fixture.updates == [true, false, true, false, true, false, true, false])

        fixture.post(NSWindow.didBecomeKeyNotification)
        await fixture.waitForUpdates(9)
        #expect(fixture.updates.last == true)
    }

    @Test("Losing key status leaves visible detail meters running")
    func visibleInactiveWindow() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        fixture.post(NSWindow.didResignKeyNotification)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.updates == [true])
    }

    @Test("Detaching and changing the host discards old window observers")
    func rebindsHost() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        fixture.tracker.removeFromSuperview()
        await fixture.waitForUpdates(2)
        #expect(fixture.updates == [true, false])

        let replacement = VisibilityTestWindow()
        replacement.fakeVisible = true
        replacement.contentView = fixture.tracker
        await fixture.waitForUpdates(3)
        fixture.post(NSWindow.willCloseNotification)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.updates == [true, false, true])

        replacement.fakeVisible = false
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: replacement)
        await fixture.waitForUpdates(4)
        #expect(fixture.updates.last == false)
    }

    @Test("Removing the detail stops pending callbacks and observer updates")
    func stopsTracking() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        fixture.window.fakeVisible = false
        fixture.post(NSWindow.didChangeOcclusionStateNotification)
        fixture.tracker.stopTracking()
        fixture.post(NSWindow.willCloseNotification)
        fixture.center.post(name: NSApplication.didHideNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.updates == [true])
    }

    @Test("Hiding the detail view stops meters without hiding its window")
    func followsViewVisibility() async {
        let fixture = Fixture(visible: true)
        fixture.window.contentView = fixture.tracker
        await fixture.waitForUpdates(1)
        fixture.tracker.isHidden = true
        await fixture.waitForUpdates(2)
        fixture.tracker.isHidden = false
        await fixture.waitForUpdates(3)
        #expect(fixture.updates == [true, false, true])
    }
}

@MainActor
private final class Fixture {
    let center = NotificationCenter()
    let window: VisibilityTestWindow
    var applicationHidden = false
    var updates: [Bool] = []
    lazy var tracker = SoundDetailWindowTrackerView(
        notificationCenter: center,
        isApplicationHidden: { [unowned self] in applicationHidden },
        onVisibilityChanged: { [unowned self] in updates.append($0) }
    )

    init(visible: Bool = false) {
        _ = NSApplication.shared
        window = VisibilityTestWindow()
        window.fakeVisible = visible
    }

    func post(_ name: Notification.Name) {
        center.post(name: name, object: window)
    }

    func waitForUpdates(_ count: Int) async {
        for _ in 0..<1_000 {
            if updates.count >= count { break }
            await Task.yield()
        }
        #expect(updates.count == count)
    }

    deinit {
        MainActor.assumeIsolated { tracker.stopTracking() }
    }
}

@MainActor
private final class VisibilityTestWindow: NSWindow {
    var fakeVisible = false
    var fakeMiniaturized = false
    var fakeOccluded = false

    override var isVisible: Bool { fakeVisible }
    override var isMiniaturized: Bool { fakeMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { fakeOccluded ? [] : [.visible] }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
}

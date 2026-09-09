import AppKit
import SwiftUI

@MainActor
final class DisplayIdentificationController {
    nonisolated struct Screen: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let name: String
        let visibleFrame: CGRect
    }

    nonisolated struct Identification: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let number: Int
        let name: String
        let frame: CGRect
    }

    nonisolated enum UnavailableReason: Error, Equatable, Sendable {
        case noScreens
        case displayNotFound(CGDirectDisplayID)
        case invalidScreenGeometry(CGDirectDisplayID)
        case stopped
    }

    static let displayDuration: Duration = .seconds(3)

    private let screenSnapshot: @MainActor () -> [Screen]
    private let present: @MainActor (Identification) -> (@MainActor () -> Void)
    private let sleep: @MainActor (Duration) async throws -> Void
    private let notificationCenter: NotificationCenter
    private var generation: UUID?
    private var hideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var closePresentations: [@MainActor () -> Void] = []
    private var isStopped = false

    var isActive: Bool { generation != nil }

    init(
        screenSnapshot: @escaping @MainActor () -> [Screen] = DisplayIdentificationController.currentScreens,
        present: @escaping @MainActor (Identification) -> (@MainActor () -> Void) = DisplayIdentificationController
            .presentPanel,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.screenSnapshot = screenSnapshot
        self.present = present
        self.sleep = sleep
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        hideTask?.cancel()
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        for close in closePresentations { close() }
    }

    @discardableResult
    func identifyAll() -> Result<[Identification], UnavailableReason> {
        identify(target: nil)
    }

    // The caller must supply a verified screen ID. This controller does no DDC identity matching.
    @discardableResult
    func identify(displayID: CGDirectDisplayID) -> Result<[Identification], UnavailableReason> {
        identify(target: displayID)
    }

    func clear() {
        generation = nil
        hideTask?.cancel()
        hideTask = nil
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        screenObserver = nil
        let closing = closePresentations
        closePresentations.removeAll()
        for close in closing { close() }
    }

    func stop() {
        isStopped = true
        clear()
    }

    private func identify(target: CGDirectDisplayID?) -> Result<[Identification], UnavailableReason> {
        clear()
        guard !isStopped else { return .failure(.stopped) }
        let screens = screenSnapshot()
        if let target, !screens.contains(where: { $0.displayID == target }) {
            return .failure(.displayNotFound(target))
        }
        guard !screens.isEmpty else { return .failure(.noScreens) }
        var identifications: [Identification] = []
        for (index, screen) in screens.enumerated() where target == nil || screen.displayID == target {
            let bounds = screen.visibleFrame
            guard bounds.width > 0, bounds.height > 0,
                [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY, bounds.width, bounds.height].allSatisfy(\.isFinite)
            else { return .failure(.invalidScreenGeometry(screen.displayID)) }
            let size = CGSize(width: min(280, bounds.width), height: min(160, bounds.height))
            let frame = CGRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
                height: size.height)
            identifications.append(
                Identification(displayID: screen.displayID, number: index + 1, name: screen.name, frame: frame))
        }

        let request = UUID()
        generation = request
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                self.clear()
            }
        }
        closePresentations = identifications.map(present)
        let sleep = sleep
        hideTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await sleep(Self.displayDuration)
            } catch {
                // Cancellation and clock failure both end this request, never a newer one.
            }
            guard let self, self.generation == request else { return }
            self.clear()
        }
        return .success(identifications)
    }

    private static func currentScreens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return Screen(displayID: number.uint32Value, name: screen.localizedName, visibleFrame: screen.visibleFrame)
        }
    }

    private static func presentPanel(_ identification: Identification) -> @MainActor () -> Void {
        let panel = IdentificationPanel(
            contentRect: identification.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: IdentificationBadge(identification: identification))
        panel.orderFrontRegardless()
        return {
            panel.orderOut(nil)
            panel.close()
            panel.contentView = nil
        }
    }
}

@MainActor
private final class IdentificationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct IdentificationBadge: View {
    let identification: DisplayIdentificationController.Identification

    var body: some View {
        VStack(spacing: 6) {
            Text(identification.number.formatted())
                .font(.system(size: 60, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(identification.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: identification.frame.width, height: identification.frame.height)
        .background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display \(identification.number), \(identification.name)")
    }
}

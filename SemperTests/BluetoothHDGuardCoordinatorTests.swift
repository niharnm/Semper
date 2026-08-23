import Foundation
import Testing
@testable import Semper

@MainActor
private final class BluetoothHDGuardTestIO {
    var claims: [String] = []
    var releases: [(original: String, protected: String, restoreOriginal: Bool)] = []
    var claimSucceeds = true

    func claim(_ uid: String) -> Bool {
        claims.append(uid)
        return claimSucceeds
    }

    func release(original: String, protected: String, restoreOriginal: Bool) {
        releases.append((original, protected, restoreOriginal))
    }
}

@Suite("Bluetooth HD Guard coordinator")
@MainActor
struct BluetoothHDGuardCoordinatorTests {
    private let headsetOutput = BluetoothHDGuardDevice(
        uid: "AA:BB:CC:output",
        name: "Test Headset",
        isBluetooth: true,
        isBuiltIn: false,
        isVirtual: false,
        isAlive: true
    )
    private let headsetInput = BluetoothHDGuardDevice(
        uid: "AA:BB:CC:input",
        name: "Test Headset",
        isBluetooth: true,
        isBuiltIn: false,
        isVirtual: false,
        isAlive: true
    )
    private let builtInInput = BluetoothHDGuardDevice(
        uid: "built-in-input",
        name: "MacBook Microphone",
        isBluetooth: false,
        isBuiltIn: true,
        isVirtual: false,
        isAlive: true
    )
    private let usbInput = BluetoothHDGuardDevice(
        uid: "usb-input",
        name: "USB Microphone",
        isBluetooth: false,
        isBuiltIn: false,
        isVirtual: false,
        isAlive: true
    )

    private func makeSettings() -> (SettingsManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemperBluetoothHDGuardTests-\(UUID().uuidString)")
        return (SettingsManager(directory: directory), directory)
    }

    private func makeSubject(
        settings: SettingsManager,
        io: BluetoothHDGuardTestIO,
        activityStore: AudioActivityStore = AudioActivityStore()
    ) -> (BluetoothHDGuardCoordinator, AudioActivityStore) {
        let coordinator = BluetoothHDGuardCoordinator(
            settings: settings,
            activityStore: activityStore,
            claimInputDevice: { io.claim($0) },
            releaseInputDevice: { original, protected, restoreOriginal in
                io.release(
                    original: original,
                    protected: protected,
                    restoreOriginal: restoreOriginal
                )
            }
        )
        return (coordinator, activityStore)
    }

    private func riskySnapshot(
        defaultInputUID: String? = nil,
        outputDevices: [BluetoothHDGuardDevice]? = nil,
        inputDevices: [BluetoothHDGuardDevice]? = nil
    ) -> BluetoothHDGuardSnapshot {
        BluetoothHDGuardSnapshot(
            defaultOutputUID: headsetOutput.uid,
            defaultInputUID: defaultInputUID ?? headsetInput.uid,
            outputDevices: outputDevices ?? [headsetOutput],
            inputDevices: inputDevices ?? [headsetInput, builtInInput, usbInput]
        )
    }

    @Test("A matching Bluetooth output and microphone prompt before protection")
    func matchingHeadsetPrompts() throws {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())

        let prompt = try #require(coordinator.pendingPrompt)
        #expect(prompt.headsetUID == headsetOutput.uid)
        #expect(prompt.originalInputUID == headsetInput.uid)
        #expect(prompt.selectedMicrophoneUID == builtInInput.uid)
        #expect(io.claims.isEmpty)
    }

    @Test("Different Bluetooth devices do not trigger protection")
    func differentBluetoothDevicesAreIgnored() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)
        let otherInput = BluetoothHDGuardDevice(
            uid: "DD:EE:FF:input",
            name: "Other Headset",
            isBluetooth: true,
            isBuiltIn: false,
            isVirtual: false,
            isAlive: true
        )

        coordinator.handleSnapshot(riskySnapshot(
            defaultInputUID: otherInput.uid,
            inputDevices: [otherInput, builtInInput]
        ))

        #expect(coordinator.pendingPrompt == nil)
        #expect(io.claims.isEmpty)
    }

    @Test("Protect once uses the selected non-Bluetooth microphone")
    func protectOnce() throws {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, activities) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.selectMicrophone(usbInput.uid)
        coordinator.respond(.protectOnce)

        let session = try #require(coordinator.activeSession)
        #expect(session.protectedInputUID == usbInput.uid)
        #expect(io.claims == [usbInput.uid])
        #expect(activities.visibleActivity?.presentation.actionTitle == "Use Headset Mic")
    }

    @Test("Not Now suppresses prompts until the risky route clears")
    func notNowSuppressesOccurrence() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.notNow)
        coordinator.handleSnapshot(riskySnapshot())
        #expect(coordinator.pendingPrompt == nil)

        coordinator.handleSnapshot(.empty)
        coordinator.handleSnapshot(riskySnapshot())
        #expect(coordinator.pendingPrompt != nil)
    }

    @Test("Always remembers the headset and microphone")
    func alwaysPersistsAndStartsNextOccurrence() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.selectMicrophone(usbInput.uid)
        coordinator.respond(.always)

        let saved = settings.bluetoothHDGuardPreference(
            for: headsetOutput.uid,
            headsetName: headsetOutput.name
        )
        #expect(saved.behavior == .always)
        #expect(saved.microphoneUID == usbInput.uid)

        coordinator.handleSnapshot(.empty)
        coordinator.handleSnapshot(riskySnapshot())
        #expect(coordinator.activeSession?.protectedInputUID == usbInput.uid)
        #expect(io.claims == [usbInput.uid, usbInput.uid])
    }

    @Test("Never remembers the headset without switching input")
    func neverPersists() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.never)
        coordinator.handleSnapshot(.empty)
        coordinator.handleSnapshot(riskySnapshot())

        #expect(settings.bluetoothHDGuardPreference(
            for: headsetOutput.uid,
            headsetName: headsetOutput.name
        ).behavior == .never)
        #expect(coordinator.pendingPrompt == nil)
        #expect(io.claims.isEmpty)
    }

    @Test("A Semper microphone selection stops protection without restoration")
    func explicitInputSelectionWins() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.protectOnce)
        coordinator.handleExplicitInputSelection(usbInput.uid)

        #expect(!coordinator.isActive)
        #expect(io.releases.count == 1)
        #expect(io.releases[0].restoreOriginal == false)
    }

    @Test("A headset microphone re-selection is corrected while protection owns input")
    func headsetReselectionIsCorrected() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.protectOnce)
        coordinator.handleSnapshot(riskySnapshot())

        #expect(io.claims == [builtInInput.uid, builtInInput.uid])
        #expect(coordinator.isActive)
    }

    @Test("Changing output ends protection and restores only owned input")
    func outputChangeEndsProtection() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.protectOnce)
        coordinator.handleSnapshot(.empty)

        #expect(!coordinator.isActive)
        #expect(io.releases.count == 1)
        #expect(io.releases[0].original == headsetInput.uid)
        #expect(io.releases[0].protected == builtInInput.uid)
        #expect(io.releases[0].restoreOriginal)
    }

    @Test("A failed microphone switch reports failure and does not enter active state")
    func failedClaim() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        io.claimSucceeds = false
        let (coordinator, activities) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.protectOnce)

        #expect(!coordinator.isActive)
        #expect(activities.visibleActivity?.presentation.message.contains("could not switch") == true)
    }

    @Test("Virtual inputs are not offered as protection microphones")
    func noEligibleMicrophone() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, activities) = makeSubject(settings: settings, io: io)
        let virtual = BluetoothHDGuardDevice(
            uid: "virtual-input",
            name: "Virtual Input",
            isBluetooth: false,
            isBuiltIn: false,
            isVirtual: true,
            isAlive: true
        )

        coordinator.handleSnapshot(riskySnapshot(
            inputDevices: [headsetInput, virtual]
        ))

        #expect(coordinator.pendingPrompt == nil)
        #expect(activities.visibleActivity?.presentation.message.contains("No non-Bluetooth") == true)
    }

    @Test("Disabling HD Guard clears prompt and active ownership")
    func disableClearsState() {
        let (settings, directory) = makeSettings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = BluetoothHDGuardTestIO()
        let (coordinator, _) = makeSubject(settings: settings, io: io)

        coordinator.handleSnapshot(riskySnapshot())
        coordinator.respond(.protectOnce)
        settings.appSettings.bluetoothHDGuardEnabled = false
        coordinator.setEnabled(false)

        #expect(coordinator.pendingPrompt == nil)
        #expect(!coordinator.isActive)
        #expect(io.releases.count == 1)

        settings.appSettings.bluetoothHDGuardEnabled = true
        coordinator.setEnabled(true)
        #expect(coordinator.pendingPrompt != nil)
    }

    @Test("Input and output UID suffixes identify the same headset")
    func hardwareIdentityMatchesDirections() {
        #expect(BluetoothHDGuardCoordinator.isSameHeadset(
            output: headsetOutput,
            input: headsetInput
        ))
    }
}

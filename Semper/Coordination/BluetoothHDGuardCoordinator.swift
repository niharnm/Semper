import Foundation

enum BluetoothHDGuardBehavior: String, CaseIterable, Equatable, Identifiable, Sendable {
    case ask
    case always
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

struct BluetoothHDGuardPreference: Equatable, Identifiable, Sendable {
    let headsetUID: String
    var headsetName: String
    var behavior: BluetoothHDGuardBehavior
    var microphoneUID: String?
    var microphoneName: String?

    var id: String { headsetUID }
}

struct BluetoothHDGuardPreferenceRecord: Codable, Equatable, Sendable {
    let behavior: String
    let headsetName: String
    let microphoneUID: String?
    let microphoneName: String?
}

struct BluetoothHDGuardDevice: Equatable, Identifiable, Sendable {
    let uid: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool
    let isVirtual: Bool
    let isAlive: Bool

    var id: String { uid }
}

struct BluetoothHDGuardSnapshot: Equatable, Sendable {
    let defaultOutputUID: String?
    let defaultInputUID: String?
    let outputDevices: [BluetoothHDGuardDevice]
    let inputDevices: [BluetoothHDGuardDevice]

    static let empty = BluetoothHDGuardSnapshot(
        defaultOutputUID: nil,
        defaultInputUID: nil,
        outputDevices: [],
        inputDevices: []
    )
}

struct BluetoothHDGuardPrompt: Equatable, Sendable {
    let headsetUID: String
    let headsetName: String
    let originalInputUID: String
    let microphones: [BluetoothHDGuardDevice]
    var selectedMicrophoneUID: String
}

struct BluetoothHDGuardSession: Equatable, Sendable {
    let headsetUID: String
    let headsetName: String
    let originalInputUID: String
    let protectedInputUID: String
    let protectedInputName: String
}

enum BluetoothHDGuardPromptResponse: Equatable, Sendable {
    case protectOnce
    case always
    case notNow
    case never
}

@Observable
@MainActor
final class BluetoothHDGuardCoordinator {
    private let settings: SettingsManager
    private let activityStore: AudioActivityStore
    private let claimInputDevice: (String) -> Bool
    private let releaseInputDevice: (_ originalUID: String, _ protectedUID: String, _ restoreOriginal: Bool) -> Void

    private(set) var pendingPrompt: BluetoothHDGuardPrompt?
    private(set) var activeSession: BluetoothHDGuardSession?

    private var latestSnapshot = BluetoothHDGuardSnapshot.empty
    private var suppressedHeadsetUIDs: Set<String> = []

    init(
        settings: SettingsManager,
        activityStore: AudioActivityStore,
        claimInputDevice: @escaping (String) -> Bool,
        releaseInputDevice: @escaping (
            _ originalUID: String,
            _ protectedUID: String,
            _ restoreOriginal: Bool
        ) -> Void
    ) {
        self.settings = settings
        self.activityStore = activityStore
        self.claimInputDevice = claimInputDevice
        self.releaseInputDevice = releaseInputDevice
    }

    var isActive: Bool {
        activeSession != nil
    }

    var availableMicrophones: [BluetoothHDGuardDevice] {
        eligibleMicrophones(in: latestSnapshot)
    }

    func handleSnapshot(_ snapshot: BluetoothHDGuardSnapshot) {
        latestSnapshot = snapshot

        if let session = activeSession {
            handleActiveSession(session, snapshot: snapshot)
            return
        }

        guard settings.appSettings.bluetoothHDGuardEnabled else {
            pendingPrompt = nil
            return
        }

        guard let risk = riskyHeadset(in: snapshot) else {
            pendingPrompt = nil
            suppressedHeadsetUIDs.removeAll()
            return
        }

        suppressedHeadsetUIDs.formIntersection([risk.headset.uid])
        guard !suppressedHeadsetUIDs.contains(risk.headset.uid) else {
            pendingPrompt = nil
            return
        }

        let microphones = eligibleMicrophones(in: snapshot)
        guard let selected = preferredMicrophone(
            for: risk.headset.uid,
            from: microphones
        ) else {
            pendingPrompt = nil
            suppressedHeadsetUIDs.insert(risk.headset.uid)
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "No non-Bluetooth microphone is available for HD Guard",
                    systemImage: "mic.slash"
                ),
                source: .automation,
                reason: .bluetoothGuard
            )
            return
        }

        let preference = settings.bluetoothHDGuardPreference(
            for: risk.headset.uid,
            headsetName: risk.headset.name
        )
        switch preference.behavior {
        case .ask:
            pendingPrompt = BluetoothHDGuardPrompt(
                headsetUID: risk.headset.uid,
                headsetName: risk.headset.name,
                originalInputUID: risk.input.uid,
                microphones: microphones,
                selectedMicrophoneUID: selected.uid
            )
        case .always:
            pendingPrompt = nil
            protect(
                headset: risk.headset,
                originalInputUID: risk.input.uid,
                microphone: selected
            )
        case .never:
            pendingPrompt = nil
            suppressedHeadsetUIDs.insert(risk.headset.uid)
        }
    }

    func selectMicrophone(_ microphoneUID: String) {
        guard var prompt = pendingPrompt,
              prompt.microphones.contains(where: { $0.uid == microphoneUID }) else {
            return
        }
        prompt.selectedMicrophoneUID = microphoneUID
        pendingPrompt = prompt
    }

    func respond(_ response: BluetoothHDGuardPromptResponse) {
        guard let prompt = pendingPrompt,
              let microphone = prompt.microphones.first(where: {
                  $0.uid == prompt.selectedMicrophoneUID
              }) else {
            return
        }
        pendingPrompt = nil

        switch response {
        case .protectOnce:
            protect(
                headset: BluetoothHDGuardDevice(
                    uid: prompt.headsetUID,
                    name: prompt.headsetName,
                    isBluetooth: true,
                    isBuiltIn: false,
                    isVirtual: false,
                    isAlive: true
                ),
                originalInputUID: prompt.originalInputUID,
                microphone: microphone
            )
        case .always:
            settings.setBluetoothHDGuardPreference(
                BluetoothHDGuardPreference(
                    headsetUID: prompt.headsetUID,
                    headsetName: prompt.headsetName,
                    behavior: .always,
                    microphoneUID: microphone.uid,
                    microphoneName: microphone.name
                )
            )
            protect(
                headset: BluetoothHDGuardDevice(
                    uid: prompt.headsetUID,
                    name: prompt.headsetName,
                    isBluetooth: true,
                    isBuiltIn: false,
                    isVirtual: false,
                    isAlive: true
                ),
                originalInputUID: prompt.originalInputUID,
                microphone: microphone
            )
        case .notNow:
            suppressedHeadsetUIDs.insert(prompt.headsetUID)
        case .never:
            settings.setBluetoothHDGuardPreference(
                BluetoothHDGuardPreference(
                    headsetUID: prompt.headsetUID,
                    headsetName: prompt.headsetName,
                    behavior: .never,
                    microphoneUID: microphone.uid,
                    microphoneName: microphone.name
                )
            )
            suppressedHeadsetUIDs.insert(prompt.headsetUID)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            handleSnapshot(latestSnapshot)
        } else {
            pendingPrompt = nil
            endProtection(restoreOriginal: true, recordActivity: activeSession != nil)
            suppressedHeadsetUIDs.removeAll()
        }
    }

    func preferencesDidChange() {
        if let session = activeSession {
            let preference = settings.bluetoothHDGuardPreference(
                for: session.headsetUID,
                headsetName: session.headsetName
            )
            if preference.behavior == .never
                || preference.microphoneUID != session.protectedInputUID {
                endProtection(restoreOriginal: true, recordActivity: true)
            }
        }
        handleSnapshot(latestSnapshot)
    }

    func handleExplicitInputSelection(_ deviceUID: String) {
        guard let session = activeSession,
              deviceUID != session.protectedInputUID else {
            return
        }
        suppressedHeadsetUIDs.insert(session.headsetUID)
        endProtection(restoreOriginal: false, recordActivity: false)
        activityStore.record(
            presentation: AudioActivityPresentation(
                message: "HD Guard stopped because you chose another microphone",
                systemImage: "person.crop.circle.badge.checkmark"
            ),
            source: .popup,
            reason: .bluetoothGuard
        )
    }

    func stopProtection() {
        endProtection(restoreOriginal: true, recordActivity: true)
    }

    func shutdown() {
        pendingPrompt = nil
        endProtection(restoreOriginal: true, recordActivity: false)
        suppressedHeadsetUIDs.removeAll()
    }

    private func handleActiveSession(
        _ session: BluetoothHDGuardSession,
        snapshot: BluetoothHDGuardSnapshot
    ) {
        guard settings.appSettings.bluetoothHDGuardEnabled,
              snapshot.defaultOutputUID == session.headsetUID,
              snapshot.outputDevices.contains(where: {
                  $0.uid == session.headsetUID && $0.isBluetooth && $0.isAlive
              }),
              snapshot.inputDevices.contains(where: {
                  $0.uid == session.protectedInputUID && $0.isAlive
              }) else {
            endProtection(restoreOriginal: true, recordActivity: true)
            handleSnapshot(snapshot)
            return
        }

        guard snapshot.defaultInputUID != session.protectedInputUID else { return }

        if let selected = snapshot.inputDevices.first(where: {
            $0.uid == snapshot.defaultInputUID
        }), !selected.isBluetooth {
            suppressedHeadsetUIDs.insert(session.headsetUID)
            endProtection(restoreOriginal: false, recordActivity: false)
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "HD Guard stopped after the microphone changed",
                    systemImage: "mic"
                ),
                source: .system,
                reason: .bluetoothGuard
            )
            return
        }

        guard claimInputDevice(session.protectedInputUID) else {
            suppressedHeadsetUIDs.insert(session.headsetUID)
            endProtection(restoreOriginal: false, recordActivity: false)
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "HD Guard could not restore the selected microphone",
                    systemImage: "exclamationmark.triangle"
                ),
                source: .automation,
                reason: .bluetoothGuard
            )
            return
        }
    }

    private func protect(
        headset: BluetoothHDGuardDevice,
        originalInputUID: String,
        microphone: BluetoothHDGuardDevice
    ) {
        guard claimInputDevice(microphone.uid) else {
            suppressedHeadsetUIDs.insert(headset.uid)
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "HD Guard could not switch to \(microphone.name)",
                    systemImage: "exclamationmark.triangle"
                ),
                source: .automation,
                reason: .bluetoothGuard
            )
            return
        }

        let session = BluetoothHDGuardSession(
            headsetUID: headset.uid,
            headsetName: headset.name,
            originalInputUID: originalInputUID,
            protectedInputUID: microphone.uid,
            protectedInputName: microphone.name
        )
        activeSession = session
        activityStore.record(
            presentation: AudioActivityPresentation(
                message: "Using \(microphone.name) to keep \(headset.name) in HD",
                systemImage: "wave.3.right",
                actionTitle: "Use Headset Mic"
            ),
            source: .automation,
            reason: .bluetoothGuard,
            action: { [weak self] in self?.stopProtection() }
        )
    }

    private func endProtection(restoreOriginal: Bool, recordActivity: Bool) {
        guard let session = activeSession else { return }
        activeSession = nil
        suppressedHeadsetUIDs.insert(session.headsetUID)
        releaseInputDevice(
            session.originalInputUID,
            session.protectedInputUID,
            restoreOriginal
        )
        if recordActivity {
            activityStore.record(
                presentation: AudioActivityPresentation(
                    message: "HD Guard stopped for \(session.headsetName)",
                    systemImage: "wave.3.right.circle"
                ),
                source: .automation,
                reason: .bluetoothGuard
            )
        }
    }

    private func eligibleMicrophones(
        in snapshot: BluetoothHDGuardSnapshot
    ) -> [BluetoothHDGuardDevice] {
        snapshot.inputDevices
            .filter { $0.isAlive && !$0.isBluetooth && !$0.isVirtual }
            .sorted {
                if $0.isBuiltIn != $1.isBuiltIn {
                    return $0.isBuiltIn
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func preferredMicrophone(
        for headsetUID: String,
        from microphones: [BluetoothHDGuardDevice]
    ) -> BluetoothHDGuardDevice? {
        let saved = settings.bluetoothHDGuardPreference(
            for: headsetUID,
            headsetName: headsetUID
        ).microphoneUID
        let preferredUIDs = [saved, settings.preferredInputDeviceUID]
            .compactMap { $0 }
            + settings.inputDevicePriorityOrder
        for uid in preferredUIDs {
            if let device = microphones.first(where: { $0.uid == uid }) {
                return device
            }
        }
        return microphones.first
    }

    private func riskyHeadset(
        in snapshot: BluetoothHDGuardSnapshot
    ) -> (headset: BluetoothHDGuardDevice, input: BluetoothHDGuardDevice)? {
        guard let output = snapshot.outputDevices.first(where: {
            $0.uid == snapshot.defaultOutputUID && $0.isBluetooth && $0.isAlive
        }),
        let input = snapshot.inputDevices.first(where: {
            $0.uid == snapshot.defaultInputUID && $0.isBluetooth && $0.isAlive
        }),
        Self.isSameHeadset(output: output, input: input) else {
            return nil
        }
        return (output, input)
    }

    nonisolated static func isSameHeadset(
        output: BluetoothHDGuardDevice,
        input: BluetoothHDGuardDevice
    ) -> Bool {
        guard output.isBluetooth, input.isBluetooth else { return false }
        if output.uid == input.uid { return true }
        if hardwareIdentity(for: output.uid) == hardwareIdentity(for: input.uid) {
            return true
        }
        return output.name.localizedCaseInsensitiveCompare(input.name) == .orderedSame
    }

    private nonisolated static func hardwareIdentity(for uid: String) -> String {
        let lowered = uid.lowercased()
        for suffix in [":input", ":output", "-input", "-output"] {
            if lowered.hasSuffix(suffix) {
                return String(lowered.dropLast(suffix.count))
            }
        }
        return lowered
    }
}

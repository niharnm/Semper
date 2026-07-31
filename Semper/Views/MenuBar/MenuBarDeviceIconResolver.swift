// Semper/Views/MenuBar/MenuBarDeviceIconResolver.swift

import AppKit
import AudioToolbox

struct MenuBarDeviceIconResolver {
    // Neutral "unknown output" glyph, sourced from the transport-type convention
    // so it stays in sync with the rest of the app rather than a private literal.
    static let fallbackSymbol = TransportType.unknown.defaultIconSymbol

    /// An override symbol that fails to resolve (hand-edited settings.json,
    /// symbol removed in a future macOS) falls back to the derived symbol —
    /// a nil NSImage downstream would freeze the status item on its last image.
    static func resolveSymbol(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID,
        overrideForUID: (String) -> String? = { _ in nil },
        isSymbolResolvable: (String) -> Bool = {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        },
        isDeviceAvailable: (AudioDevice) -> Bool = { $0.id.isDeviceAlive() },
        uidForDefaultID: (AudioDeviceID) -> String? = { try? $0.readDeviceUID() },
        symbolForDevice: (AudioDevice) -> String = { $0.id.suggestedIconSymbol() },
        symbolForDefaultID: (AudioDeviceID) -> String = { id in
            guard id.isValid else { return Self.fallbackSymbol }
            return id.suggestedIconSymbol()
        }
    ) -> String {
        func overrideSymbol(forUID uid: String) -> String? {
            guard let symbol = overrideForUID(uid), isSymbolResolvable(symbol) else { return nil }
            return symbol
        }

        let devicesByUID = Dictionary(outputDevices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Match macOS's sound menu: the persistent icon represents the device
        // currently receiving system audio, even if Semper's saved priority
        // order has another connected device above it.
        if let defaultDevice = outputDevices.first(where: { $0.id == defaultDeviceID }),
           isDeviceAvailable(defaultDevice) {
            return overrideSymbol(forUID: defaultDevice.uid) ?? symbolForDevice(defaultDevice)
        }

        for uid in priorityOrder {
            guard let device = devicesByUID[uid], isDeviceAvailable(device) else { continue }
            return overrideSymbol(forUID: uid) ?? symbolForDevice(device)
        }

        if defaultDeviceID.isValid {
            if let uid = uidForDefaultID(defaultDeviceID), let symbol = overrideSymbol(forUID: uid) {
                return symbol
            }
            return symbolForDefaultID(defaultDeviceID)
        }

        return fallbackSymbol
    }
}

// Semper/Views/Settings/Components/SystemSoundsDevicePicker.swift
import SwiftUI

/// Trailing-slot wrapper around the popup's `DevicePicker` (single-mode)
/// for the system-sounds output selector. Keeps the existing dropdown
/// behavior (System Audio + per-device entries) while letting `CardRow`
/// own the icon, title, and description.
@MainActor
struct SystemSoundsDevicePicker: View {
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let selectedDeviceUID: String?
    let defaultDeviceUID: String?
    let isFollowingDefault: Bool
    let onDeviceSelected: (String) -> Void
    let onSelectFollowDefault: () -> Void

    var body: some View {
        DevicePicker(
            devices: devices,
            deviceIconOverrides: deviceIconOverrides,
            selectedDeviceUID: selectedDeviceUID ?? "",
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            triggerWidth: 160,
            onDeviceSelected: { onDeviceSelected($0) },
            onSelectFollowDefault: { onSelectFollowDefault() }
        )
    }
}

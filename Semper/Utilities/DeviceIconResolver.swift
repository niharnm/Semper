// Semper/Utilities/DeviceIconResolver.swift
import AppKit

/// Applies the device-icon display precedence:
/// user override → automatic icon (driver image or suggested SF Symbol).
enum DeviceIconResolver {
    /// An override symbol that fails to resolve (hand-edited settings.json,
    /// symbol removed in a future macOS) falls back to the automatic icon
    /// rather than producing a blank glyph.
    static func displayIcon(
        overrideSymbol: String?,
        automatic: NSImage?,
        deviceName: String
    ) -> NSImage? {
        if let overrideSymbol,
           let image = NSImage(systemSymbolName: overrideSymbol, accessibilityDescription: deviceName) {
            return image
        }
        return automatic
    }
}

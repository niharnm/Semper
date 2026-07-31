import AppKit
import SwiftUI

struct AppIdentityButton: View {
    let icon: NSImage
    let name: String
    let pid: pid_t?
    let bundleID: String?
    let usesFallbackIcon: Bool
    let isProducingAudio: Bool
    let onActivate: () -> Bool

    @State private var isHovered = false
    @State private var showsIdentity = false

    var body: some View {
        Button {
            if !onActivate() {
                showsIdentity = true
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DesignTokens.Colors.appIconTintFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(DesignTokens.Colors.appIconTintBorder, lineWidth: 1)
                    }
                    .shadow(
                        color: DesignTokens.Colors.appIconTintShadow,
                        radius: 3,
                        x: 0,
                        y: 2
                    )

                if usesFallbackIcon {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.systemOrange)
                } else {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .frame(width: 28, height: 28)
            .opacity(isHovered ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Identify or open \(name)")
        .help(identityHelp)
        .popover(isPresented: $showsIdentity, arrowEdge: .trailing) {
            identityDetails
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var identityHelp: String {
        var lines = [name]
        if let pid {
            lines.append("PID \(pid)")
        }
        lines.append(bundleID ?? "Bundle ID not reported by macOS")
        lines.append("Click to bring this application forward")
        return lines.joined(separator: "\n")
    }

    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.headline)

            Label(
                isProducingAudio ? "Currently producing audio" : "Pinned, not currently producing audio",
                systemImage: isProducingAudio ? "waveform" : "pin"
            )
            .font(.caption)
            .foregroundStyle(
                isProducingAudio
                    ? DesignTokens.Colors.systemGreen
                    : DesignTokens.Colors.textSecondary
            )

            Divider()

            if let pid {
                identityRow(label: "Process", value: "PID \(pid)")
            }
            identityRow(label: "Bundle", value: bundleID ?? "Not reported")

            Text("macOS does not expose an application window for this audio process.")
                .font(.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .font(.caption)
    }
}

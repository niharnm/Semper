// Semper/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var yearText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        return startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                Text("Semper")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(versionShort) (\(buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                AboutLinkChip(
                    label: "Website",
                    icon: "globe",
                    hoverIcon: "globe",
                    hoverColor: .blue,
                    url: DesignTokens.Links.website,
                    isPrimary: true
                )
                AboutLinkChip(
                    label: "GPL-3.0",
                    icon: "doc.text",
                    hoverIcon: "doc.text.fill",
                    hoverColor: .orange,
                    url: DesignTokens.Links.license
                )
            }

            footer
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Semper is led by Nihar Manchikakapudi.")
            Text("© \(yearText) Nihar Manchikakapudi and contributors")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}

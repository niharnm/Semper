// Semper/Views/Previews/PreviewContainer.swift
import SwiftUI

/// Container view for consistent preview styling
/// Wraps content with the popup glass background matching the app's menu bar popup
struct PreviewContainer<Content: View>: View {
    let width: CGFloat
    let content: Content

    init(
        width: CGFloat = DesignTokens.Dimensions.popupWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: width)
            .padding(DesignTokens.Spacing.lg)
            .popupGlassBackground()
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}

/// Narrow preview container for individual components
struct ComponentPreviewContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DesignTokens.Spacing.lg)
            .popupGlassBackground()
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Previews

#Preview("Preview Container") {
    PreviewContainer {
        VStack(alignment: .leading, spacing: 12) {
            Text("OUTPUT DEVICES")
                .sectionHeaderStyle()

            Text("Sample content goes here")
                .foregroundStyle(.primary)

            Text("Secondary information")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Component Preview") {
    ComponentPreviewContainer {
        HStack {
            Image(systemName: "speaker.wave.2")
            Text("Test Component")
            Spacer()
            Text("100%")
        }
    }
}
